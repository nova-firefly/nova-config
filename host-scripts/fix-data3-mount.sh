#!/usr/bin/env bash
# fix-data3-mount.sh — One-off repair after the 2026-10 motherboard replacement.
#
# Problem: /etc/fstab mounted /data3 by kernel name (/dev/sdd). The new board enumerates
# disks differently, so /dev/sdd is now the 931G data2 disk — it is mounted at BOTH /data2
# and /data3 — and the real 9.1T data3 disk (now /dev/sdc) is not mounted at all. Docker
# created an empty /data3/immich_data stub, and immich_server crash-loops on its folder check.
#
# Fix: mount the data3 filesystem by UUID (UUIDs belong to the filesystem, not the port).
#
# Safety properties:
#   - Dry run by default. Nothing changes without --apply AND a typed confirmation.
#   - Both UUIDs are pinned; it aborts if the current state is not exactly what was diagnosed.
#   - The data3 disk is checked read-only (e2fsck -n) and inspected via a read-only,
#     no-journal-replay mount before anything else happens.
#   - Deletes nothing. The empty stub at /data2/immich_data is left for you to rmdir.
#   - Only the containers that bind-mount /data3 are cycled, not their whole stacks.
#   - Pauses nova-reconcile/nova-heal so they can't restart stacks mid-swap.
#   - /data3 is mounted manually first; fstab is only rewritten after that mount is verified.
#     A failure before that point leaves fstab untouched, so a reboot returns to the old state.
#   - Every step is logged to /root/fix-data3-<timestamp>.log.
#
# Usage:
#   sudo ./host-scripts/fix-data3-mount.sh            # dry run: checks only
#   sudo ./host-scripts/fix-data3-mount.sh --apply    # do it
#
# NOVA_DIR overrides the nova-config location (default: /home/koonan/git/nova-config).

set -euo pipefail

DATA3_UUID="1d2d4241-db45-4c2a-805a-0fde2912baa3"   # 9.1T — the real /data3
DATA2_UUID="95b71e16-4c3f-4827-8110-722afeec4b79"   # 931G — /data2 (wrongly also at /data3)
OLD_FSTAB_LINE="/dev/sdd /data3 ext4 defaults 0 0"
NEW_FSTAB_LINE="UUID=${DATA3_UUID} /data3 ext4 defaults,nofail 0 2"
IMMICH_DIRS=(encoded-video library upload profile thumbs backups)
TIMERS=(nova-reconcile.timer nova-heal.timer)
NOVA_DIR="${NOVA_DIR:-/home/koonan/git/nova-config}"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

TS="$(date +%Y%m%d-%H%M%S)"
LOG="/root/fix-data3-${TS}.log"
PROBE=""
STOPPED_TIMERS=()

die() {
  echo
  echo "ABORT: $*" >&2
  [[ -n "$PROBE" ]] && cleanup_probe
  if ((${#STOPPED_TIMERS[@]})); then
    echo "Timers left STOPPED on purpose: ${STOPPED_TIMERS[*]}" >&2
    echo "Restart them once /data3 is sorted: systemctl start ${STOPPED_TIMERS[*]}" >&2
  fi
  echo "Log: $LOG" >&2
  exit 1
}
step() { echo; echo "── $* ──"; }
ok()   { echo "  ok: $*"; }

cleanup_probe() {
  if [[ -n "$PROBE" ]]; then
    mountpoint -q "$PROBE" && umount "$PROBE"
    rmdir "$PROBE" 2>/dev/null || true
    PROBE=""
  fi
}
trap 'cleanup_probe' EXIT

uuid_of() { blkid -s UUID -o value "$1" 2>/dev/null || true; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
exec > >(tee -a "$LOG") 2>&1
echo "fix-data3-mount.sh  mode=$([[ $APPLY == 1 ]] && echo APPLY || echo DRY-RUN)  $(date)"

# ── 1. Preflight: confirm the state matches the diagnosis ──────────────────────
step "1. Preflight"

for bin in blkid findmnt lsblk e2fsck mountpoint docker systemctl; do
  command -v "$bin" >/dev/null || die "missing command: $bin"
done
[[ -x "$NOVA_DIR/nova.sh" ]] || die "nova.sh not found at $NOVA_DIR (set NOVA_DIR)"

DEV3="$(blkid -U "$DATA3_UUID" || true)"
[[ -n "$DEV3" ]] || die "no filesystem with UUID $DATA3_UUID — is the 9.1T disk connected?"
SIZE3="$(lsblk -bdno SIZE "$DEV3")"
TYPE3="$(blkid -s TYPE -o value "$DEV3")"
[[ "$TYPE3" == "ext4" ]] || die "$DEV3 is $TYPE3, expected ext4"
(( SIZE3 > 8000000000000 )) || die "$DEV3 is only $SIZE3 bytes; expected ~9.1T"
ok "data3 filesystem is $DEV3 ($(lsblk -dno SIZE "$DEV3"), ext4)"

if findmnt -rn -S "$DEV3" >/dev/null; then
  CUR="$(findmnt -rn -o TARGET -S "$DEV3" | tr '\n' ' ')"
  if [[ "$(uuid_of "$(findmnt -rn -o SOURCE /data3)")" == "$DATA3_UUID" ]]; then
    echo "  /data3 is already the 9.1T disk. Nothing to fix."
    exit 0
  fi
  die "$DEV3 is already mounted at: $CUR — not touching it"
fi
ok "$DEV3 is not mounted anywhere"

SRC3="$(findmnt -rn -o SOURCE /data3 || true)"
[[ -n "$SRC3" ]] || die "/data3 is not mounted at all — state differs from diagnosis"
[[ "$(uuid_of "$SRC3")" == "$DATA2_UUID" ]] || die "/data3 is mounted from $SRC3, not the data2 disk — state differs from diagnosis"
SRC2="$(findmnt -rn -o SOURCE /data2 || true)"
[[ "$(uuid_of "$SRC2")" == "$DATA2_UUID" ]] || die "/data2 is not the data2 disk ($SRC2) — state differs from diagnosis"
ok "/data2 and /data3 are both the data2 disk ($SRC3), as diagnosed"

mapfile -t FSTAB3 < <(awk '$1 !~ /^#/ && $2 == "/data3"' /etc/fstab)
(( ${#FSTAB3[@]} == 1 )) || die "expected exactly one /data3 line in /etc/fstab, found ${#FSTAB3[@]}"
[[ "$(echo "${FSTAB3[0]}" | tr -s ' \t' ' ')" == "$OLD_FSTAB_LINE" ]] \
  || die "/data3 fstab line is '${FSTAB3[0]}', expected '$OLD_FSTAB_LINE'"
ok "fstab has the expected /dev/sdd line"

# ── 2. Read-only checks of the data3 disk ──────────────────────────────────────
step "2. Read-only filesystem check (e2fsck -n, changes nothing)"
if e2fsck -n "$DEV3"; then
  ok "e2fsck clean"
else
  die "e2fsck -n reported problems (exit $?). Do not mount — send the output above."
fi

step "3. Read-only peek at the data3 disk"
PROBE="$(mktemp -d /mnt/data3-probe.XXXXXX)"
mount -t ext4 -o ro,noload "$DEV3" "$PROBE"
echo "  top level:"; ls -la "$PROBE" | sed 's/^/    /'
missing=()
for d in "${IMMICH_DIRS[@]}"; do
  [[ -e "$PROBE/immich_data/$d/.immich" ]] || missing+=("$d")
done
(( ${#missing[@]} == 0 )) || die "immich_data on $DEV3 is missing markers for: ${missing[*]}"
ok "immich_data has all ${#IMMICH_DIRS[@]} .immich markers"
echo "  library folders: $(find "$PROBE/immich_data/library" -mindepth 1 -maxdepth 1 | wc -l)  upload folders: $(find "$PROBE/immich_data/upload" -mindepth 1 -maxdepth 1 | wc -l)"
df -h "$PROBE" | sed 's/^/    /'
cleanup_probe

# ── 3. Which services hold /data3 open ─────────────────────────────────────────
# Only these services are cycled, not their whole stacks (homepage lives in infra next to
# traefik; no reason to take routing down).
step "4. Containers bind-mounting /data3"
declare -A STACKS=()   # stack -> space-separated compose service names
while read -r cid; do
  [[ -n "$cid" ]] || continue
  binds="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}')"
  grep -qE '^/data3(/|$)' <<<"$binds" || continue
  name="$(docker inspect "$cid" --format '{{.Name}}')"
  svc="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}')"
  wd="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  stack="$(basename "$wd")"
  [[ -n "$wd" && -n "$svc" && -f "$NOVA_DIR/$stack/compose.yaml" ]] \
    || die "container $name uses /data3 but isn't from a nova.sh stack (working_dir='$wd')"
  echo "  $name  →  $stack/$svc"
  STACKS["$stack"]="${STACKS[$stack]:-} $svc"
done < <(docker ps -aq)
STACK_LIST=("${!STACKS[@]}")
(( ${#STACK_LIST[@]} )) || die "no containers use /data3 — unexpected"
for s in "${STACK_LIST[@]}"; do ok "will cycle $s:${STACKS[$s]}"; done

# ── Plan + confirmation ────────────────────────────────────────────────────────
step "Plan"
cat <<EOF
  a. Pause timers: ${TIMERS[*]}
  b. ./nova.sh down <stack> <services> — only the services listed in step 4
  c. umount /data3 (the duplicate data2 mount; /data2 itself is untouched)
  d. mount UUID=$DATA3_UUID at /data3 and verify immich_data
  e. Back up /etc/fstab → /etc/fstab.bak.fix-data3.$TS, replace the /data3 line with:
       $NEW_FSTAB_LINE
  f. ./nova.sh up <stack> <services> — the same services
  g. Restart timers
EOF

if (( ! APPLY )); then
  echo; echo "DRY RUN complete — all checks passed. Re-run with --apply to make changes."
  exit 0
fi

echo
read -r -p "Type 'fix data3' to proceed: " answer </dev/tty
[[ "$answer" == "fix data3" ]] || die "not confirmed"

# ── 4. Apply ───────────────────────────────────────────────────────────────────
step "a. Pausing timers"
for t in "${TIMERS[@]}"; do
  if systemctl is-active -q "$t"; then
    systemctl stop "$t"; STOPPED_TIMERS+=("$t"); ok "stopped $t"
  fi
done
for svc in nova-reconcile.service nova-heal.service; do
  while systemctl is-active -q "$svc"; do echo "  waiting for running $svc to finish..."; sleep 5; done
done

step "b. Stopping services"
for s in "${STACK_LIST[@]}"; do
  # shellcheck disable=SC2086  # word-split the service list on purpose
  "$NOVA_DIR/nova.sh" down "$s" ${STACKS[$s]} || die "nova.sh down $s failed"
done
still="$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' | grep -E ' /data3(/| |$)' || true)"
[[ -z "$still" ]] || die "containers still running with /data3 mounted: $still"
ok "no running container holds /data3"

step "c. Unmounting the duplicate /data3"
umount /data3 || die "umount /data3 failed (busy?). Check: fuser -vm /data3"
if [[ -n "$(ls -A /data3)" ]]; then
  mount /data3 || true
  die "/data3 mountpoint on the root disk is not empty — inspect before continuing (old mount restored)"
fi
ok "/data3 unmounted, mountpoint empty"

step "d. Mounting the 9.1T disk"
if ! mount -t ext4 "UUID=$DATA3_UUID" /data3; then
  mount /data3 || true
  die "mounting UUID=$DATA3_UUID failed — old mount restored, fstab unchanged"
fi
[[ "$(uuid_of "$(findmnt -rn -o SOURCE /data3)")" == "$DATA3_UUID" ]] || die "/data3 is not the expected filesystem after mount"
[[ "$(uuid_of "$(findmnt -rn -o SOURCE /data2)")" == "$DATA2_UUID" ]] || die "/data2 changed unexpectedly"
for d in "${IMMICH_DIRS[@]}"; do
  [[ -e "/data3/immich_data/$d/.immich" ]] || die "/data3/immich_data/$d/.immich missing after mount"
done
ok "/data3 = $DEV3, immich markers present"

step "e. Updating /etc/fstab"
BAK="/etc/fstab.bak.fix-data3.$TS"
cp -a /etc/fstab "$BAK"; ok "backup at $BAK"
NEW="$(mktemp)"
awk -v new="$NEW_FSTAB_LINE" '$1 !~ /^#/ && $2 == "/data3" { print new; next } { print }' /etc/fstab > "$NEW"
diff -u /etc/fstab "$NEW" || true
findmnt --verify --tab-file "$NEW" || die "new fstab failed verification — /etc/fstab unchanged ($NEW kept)"
cat "$NEW" > /etc/fstab && rm -f "$NEW"
systemctl daemon-reload
ok "fstab updated"

step "f. Starting services"
failed=()
for s in "${STACK_LIST[@]}"; do
  # shellcheck disable=SC2086
  "$NOVA_DIR/nova.sh" up "$s" ${STACKS[$s]} || failed+=("$s")
done

step "g. Restarting timers"
for t in "${STOPPED_TIMERS[@]}"; do systemctl start "$t" && ok "started $t"; done
STOPPED_TIMERS=()

step "Done"
findmnt /data2; findmnt /data3
(( ${#failed[@]} == 0 )) || echo "WARNING: nova.sh up failed for: ${failed[*]} — check $LOG"
cat <<EOF

Follow-ups (not done by this script):
  - Empty Docker-made stub left on the data2 disk:   rmdir /data2/immich_data
  - Files Sonarr/Radarr wrote to /data3 since Oct 16 landed on the data2 disk:
      find /data2 -newermt 2026-10-16 -type f
  - Watch immich come up:   docker logs -f immich_server
Log: $LOG
EOF
