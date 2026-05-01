#!/usr/bin/env bash
# host-disk-settings.sh — One-time host configuration for minimal disk footprint.
#
# Run as root:
#   sudo bash host-disk-settings.sh
#
# What it does:
#   1. Caps journald at 200MB (currently unbounded at 2.7GB)
#   2. Adds maxsize 50M to rsyslog logrotate (prevents single logs growing huge)
#   3. Removes snap entirely (only system snaps remain; gh is already via apt)
#   4. Installs the weekly docker/host cleanup cron

set -euo pipefail

log() { echo "[host-disk-settings] $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (sudo bash $0)" >&2
  exit 1
fi

# ── 1. Journal size cap ─────────────────────────────────────────────────────

JOURNALD_CONF="/etc/systemd/journald.conf"

if grep -q '^SystemMaxUse=' "$JOURNALD_CONF" 2>/dev/null; then
  log "journald: SystemMaxUse already set, skipping"
else
  log "journald: Setting SystemMaxUse=200M"
  sed -i '/^\[Journal\]/a SystemMaxUse=200M' "$JOURNALD_CONF"
  systemctl restart systemd-journald
  log "journald: Restarted — will vacuum on next rotation"
fi

# ── 2. Logrotate maxsize for rsyslog ────────────────────────────────────────

LOGROTATE_RSYSLOG="/etc/logrotate.d/rsyslog"

if grep -q 'maxsize' "$LOGROTATE_RSYSLOG" 2>/dev/null; then
  log "logrotate: maxsize already configured, skipping"
else
  log "logrotate: Adding maxsize 50M to rsyslog config"
  sed -i '/rotate 4/a\        maxsize 50M' "$LOGROTATE_RSYSLOG"
  log "logrotate: Updated — logs will now rotate when exceeding 50MB"
fi

# ── 3. Remove snap ──────────────────────────────────────────────────────────

if command -v snap &>/dev/null; then
  log "snap: Removing all snaps and snapd"

  # Remove snaps in dependency order (apps first, then bases, then snapd)
  for snap_name in lxd gh; do
    if snap list "$snap_name" &>/dev/null; then
      log "snap: Removing $snap_name"
      snap remove --purge "$snap_name" 2>/dev/null || true
    fi
  done

  for snap_name in core24 core20 core18; do
    if snap list "$snap_name" &>/dev/null; then
      log "snap: Removing $snap_name"
      snap remove --purge "$snap_name" 2>/dev/null || true
    fi
  done

  if snap list snapd &>/dev/null; then
    log "snap: Removing snapd"
    snap remove --purge snapd 2>/dev/null || true
  fi

  log "snap: Purging snapd package"
  apt purge -y snapd 2>/dev/null || true
  rm -rf /snap /var/snap /var/lib/snapd /root/snap /home/*/snap

  # Prevent snapd from being re-installed as a dependency
  cat > /etc/apt/preferences.d/no-snapd <<'PREF'
Package: snapd
Pin: release *
Pin-Priority: -1
PREF

  log "snap: Removed and pinned to prevent reinstall"
else
  log "snap: Already removed, skipping"
fi

# ── 4. Install weekly cleanup cron ──────────────────────────────────────────

CRON_SCRIPT="/etc/cron.weekly/nova-disk-cleanup"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/nova-disk-cleanup.sh"

if [[ -f "$SOURCE_SCRIPT" ]]; then
  log "cron: Installing weekly cleanup to $CRON_SCRIPT"
  cp "$SOURCE_SCRIPT" "$CRON_SCRIPT"
  chmod +x "$CRON_SCRIPT"
  log "cron: Installed — will run weekly via anacron"
else
  log "cron: WARNING — nova-disk-cleanup.sh not found at $SOURCE_SCRIPT"
  log "cron: Copy it to host-scripts/ and re-run, or install manually"
fi

# ── Done ────────────────────────────────────────────────────────────────────

log ""
log "Settings applied. Summary:"
log "  - journald: capped at 200MB"
log "  - logrotate: rsyslog maxsize 50M"
log "  - snap: removed and pinned"
log "  - weekly cron: $([ -f "$CRON_SCRIPT" ] && echo 'installed' || echo 'needs manual install')"
log ""
log "NOTE: fail2ban is not running (systemctl status fail2ban). Fix separately."
