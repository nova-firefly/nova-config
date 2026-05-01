#!/usr/bin/env bash
# nova-disk-cleanup.sh — Weekly host disk cleanup for a Docker-only server.
#
# Installed to /etc/cron.weekly/nova-disk-cleanup by host-disk-settings.sh.
# Can also be run manually: sudo bash nova-disk-cleanup.sh
#
# What it cleans:
#   1. Dangling Docker images (untagged, replaced by newer pulls)
#   2. Orphaned anonymous Docker volumes (not attached to any container)
#   3. Docker build cache older than 7 days
#   4. APT package cache
#   5. Failed login logs (btmp) — truncated, not deleted
#   6. Old temp files in /tmp and /var/tmp (>7 days)
#   7. Vacuum journald to configured limit

set -euo pipefail

log() { echo "[nova-disk-cleanup] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Record starting usage
BEFORE=$(df / --output=used | tail -1)

log "=== Starting weekly disk cleanup ==="

# ── 1. Docker: dangling images ──────────────────────────────────────────────

PRUNED=$(docker image prune -f 2>/dev/null | tail -1)
log "Images: $PRUNED"

# ── 2. Docker: orphaned anonymous volumes ────────────────────────────────────

PRUNED=$(docker volume prune -f 2>/dev/null | tail -1)
log "Volumes: $PRUNED"

# ── 3. Docker: stale build cache ────────────────────────────────────────────

PRUNED=$(docker builder prune -f --filter "until=168h" 2>/dev/null | tail -1)
log "Build cache: $PRUNED"

# ── 4. APT cache ────────────────────────────────────────────────────────────

apt-get clean -y >/dev/null 2>&1
log "APT cache: cleaned"

# ── 5. Failed login logs ────────────────────────────────────────────────────

for f in /var/log/btmp /var/log/btmp.1; do
  if [[ -f "$f" ]]; then
    truncate -s 0 "$f"
  fi
done
log "btmp: truncated"

# ── 6. Old temp files ───────────────────────────────────────────────────────

TEMP_CLEANED=$(find /tmp /var/tmp -type f -atime +7 -delete -print 2>/dev/null | wc -l)
log "Temp files: removed $TEMP_CLEANED files older than 7 days"

# ── 7. Journal vacuum ───────────────────────────────────────────────────────

journalctl --vacuum-size=200M >/dev/null 2>&1
log "Journal: vacuumed to 200M limit"

# ── Summary ─────────────────────────────────────────────────────────────────

AFTER=$(df / --output=used | tail -1)
SAVED_KB=$(( BEFORE - AFTER ))

if (( SAVED_KB > 0 )); then
  if (( SAVED_KB > 1048576 )); then
    SAVED="$(( SAVED_KB / 1048576 ))GB"
  elif (( SAVED_KB > 1024 )); then
    SAVED="$(( SAVED_KB / 1024 ))MB"
  else
    SAVED="${SAVED_KB}KB"
  fi
  log "=== Done — reclaimed ~${SAVED} ==="
else
  log "=== Done — disk already clean ==="
fi
