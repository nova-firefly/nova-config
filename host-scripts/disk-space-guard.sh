#!/usr/bin/env bash
# disk-space-guard.sh — Monitor media disk usage; pause qBittorrent when critically low.
#
# Deploy:
#   sudo cp disk-space-guard.sh /usr/local/bin/disk-space-guard.sh
#   sudo chmod +x /usr/local/bin/disk-space-guard.sh
#
# Reads credentials from NOVA_ENV_FILE (defaults to ~/nova-config/.env).
# Override at runtime: NOVA_ENV_FILE=/path/to/.env disk-space-guard.sh
#
# State files in /run/disk-space-guard/ (ephemeral; reset on reboot):
#   qb-paused     — exists when this script has paused qBittorrent
#   warn-notified — timestamp file; suppresses repeat warn alerts for 4h

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

WARN_PCT=85          # % used → send ntfy warning (debounced to 4h)
CRIT_PCT=92          # % used → pause qBittorrent + send ntfy critical

# Space-separated list of mount points to monitor.
# Each is checked independently; any one hitting CRIT triggers QB pause.
MONITOR_MOUNTS="/data1 /data2 /data3"

QB_HOST="http://localhost:8090"

# Source .env to get NOVA_DOMAIN, NTFY_TOPIC, QBITTORRENT_USER, QBITTORRENT_PASS
NOVA_ENV_FILE="${NOVA_ENV_FILE:-${HOME}/nova-config/.env}"

STATE_DIR="/run/disk-space-guard"
QB_PAUSED_FLAG="${STATE_DIR}/qb-paused"
WARN_NOTIFIED_FLAG="${STATE_DIR}/warn-notified"
WARN_DEBOUNCE_SECONDS=$((4 * 3600))

# ── Load environment ──────────────────────────────────────────────────────────

if [[ -f "${NOVA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${NOVA_ENV_FILE}"; set +o allexport
fi

NOVA_DOMAIN="${NOVA_DOMAIN:-}"
NTFY_TOPIC="${NTFY_TOPIC:-nova-compose}"
QB_USER="${QBITTORRENT_USER:-admin}"
QB_PASS="${QBITTORRENT_PASS:-}"

mkdir -p "${STATE_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ntfy() {
  local title="$1" body="$2" tags="$3" priority="${4:-default}"
  [[ -z "${NOVA_DOMAIN}" || -z "${NTFY_TOPIC}" ]] && return 0
  curl -sf \
    -H "Title: ${title}" \
    -H "Tags: ${tags}" \
    -H "Priority: ${priority}" \
    -d "${body}" \
    "https://ntfy.${NOVA_DOMAIN}/${NTFY_TOPIC}" \
    >/dev/null 2>&1 || true
}

disk_used_pct() {
  df "$1" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

disk_avail_human() {
  df -h "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

qbt_login() {
  QB_COOKIE=$(curl -sf -c - \
    --data "username=${QB_USER}&password=${QB_PASS}" \
    "${QB_HOST}/api/v2/auth/login" 2>/dev/null \
    | awk '/SID/ {print $NF}') || true
}

qbt_pause_all() {
  [[ -z "${QB_COOKIE:-}" ]] && return 1
  curl -sf -b "SID=${QB_COOKIE}" \
    "${QB_HOST}/api/v2/torrents/pause" \
    --data "hashes=all" >/dev/null 2>&1 || true
}

qbt_resume_all() {
  [[ -z "${QB_COOKIE:-}" ]] && return 1
  curl -sf -b "SID=${QB_COOKIE}" \
    "${QB_HOST}/api/v2/torrents/resume" \
    --data "hashes=all" >/dev/null 2>&1 || true
}

warn_debounced() {
  # Returns 0 (send) if no notification sent in the last WARN_DEBOUNCE_SECONDS
  if [[ -f "${WARN_NOTIFIED_FLAG}" ]]; then
    local last_notified
    last_notified=$(cat "${WARN_NOTIFIED_FLAG}")
    local now
    now=$(date +%s)
    if (( now - last_notified < WARN_DEBOUNCE_SECONDS )); then
      return 1
    fi
  fi
  return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

highest_pct=0
critical_mounts=()
warn_mounts=()

for mount in ${MONITOR_MOUNTS}; do
  # Skip mounts that don't exist on this host
  [[ -d "${mount}" ]] || continue

  pct=$(disk_used_pct "${mount}")
  [[ -z "${pct}" ]] && continue

  if (( pct >= CRIT_PCT )); then
    critical_mounts+=("${mount}(${pct}%)")
  elif (( pct >= WARN_PCT )); then
    avail=$(disk_avail_human "${mount}")
    warn_mounts+=("${mount}(${pct}%, ${avail} free)")
  fi

  (( pct > highest_pct )) && highest_pct=${pct}
done

# ── Critical path: pause qBittorrent ─────────────────────────────────────────

if (( ${#critical_mounts[@]} > 0 )); then
  mounts_str="${critical_mounts[*]}"
  log "CRITICAL: ${mounts_str} — pausing qBittorrent"

  qbt_login
  qbt_pause_all

  if [[ ! -f "${QB_PAUSED_FLAG}" ]]; then
    touch "${QB_PAUSED_FLAG}"
    ntfy \
      "Disk Critical — Downloads Paused" \
      "qBittorrent paused. Disks at: ${mounts_str}" \
      "rotating_light" \
      "urgent"
  else
    # Already paused — send a reminder every WARN_DEBOUNCE_SECONDS
    if warn_debounced; then
      ntfy \
        "Disk Still Critical — Downloads Still Paused" \
        "Disks at: ${mounts_str}. Free up space to resume." \
        "rotating_light" \
        "high"
      date +%s > "${WARN_NOTIFIED_FLAG}"
    fi
  fi

# ── Recovery path: resume qBittorrent if we paused it ────────────────────────

elif [[ -f "${QB_PAUSED_FLAG}" ]]; then
  log "Disk usage recovered — resuming qBittorrent"

  qbt_login
  qbt_resume_all

  rm -f "${QB_PAUSED_FLAG}" "${WARN_NOTIFIED_FLAG}"

  ntfy \
    "Disk Space Recovered — Downloads Resumed" \
    "Disk usage back below ${CRIT_PCT}%. qBittorrent resumed." \
    "white_check_mark" \
    "default"

# ── Warning path: notify only ─────────────────────────────────────────────────

elif (( ${#warn_mounts[@]} > 0 )); then
  if warn_debounced; then
    mounts_str="${warn_mounts[*]}"
    log "WARNING: ${mounts_str}"
    ntfy \
      "Disk Space Warning" \
      "Getting full: ${mounts_str}" \
      "warning" \
      "default"
    date +%s > "${WARN_NOTIFIED_FLAG}"
  fi

# ── All clear ────────────────────────────────────────────────────────────────

else
  # Clear warn debounce flag when everything is healthy again
  rm -f "${WARN_NOTIFIED_FLAG}"
  log "OK: all mounts below ${WARN_PCT}% (highest: ${highest_pct}%)"
fi
