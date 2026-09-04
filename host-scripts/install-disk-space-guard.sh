#!/usr/bin/env bash
# install-disk-space-guard.sh — Install the disk space guard systemd timer on the host.
#
# Run once as root from anywhere in the nova-config repo:
#   sudo ./host-scripts/install-disk-space-guard.sh
#
# What it does:
#   - Deploys disk-space-guard.sh to /usr/local/bin/
#   - Installs disk-space-guard.service + .timer to /etc/systemd/system/
#     (substituting the real nova-config path for @NOVA_CONFIG_DIR@)
#   - Enables and starts the timer (fires 2 min after boot, then every 15 minutes)
#   - Warns via ntfy at WARN_PCT and pauses qBittorrent at CRIT_PCT
#
# Requires NTFY_TOPIC, NOVA_DOMAIN, QBITTORRENT_USER and QBITTORRENT_PASS in
# nova-config/.env — without the qBittorrent credentials the pause silently no-ops.
#
# To uninstall:
#   sudo systemctl disable --now disk-space-guard.timer
#   sudo rm /etc/systemd/system/disk-space-guard.{service,timer} /usr/local/bin/disk-space-guard.sh
#   sudo systemctl daemon-reload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOVA_CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${NOVA_CONFIG_DIR}/.env"

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env not found at ${ENV_FILE}" >&2
  exit 1
fi

echo "Installing disk-space-guard using nova-config at: ${NOVA_CONFIG_DIR}"

# Warn early about the credentials the pause path depends on. The guard swallows
# curl failures with "|| true", so a missing password fails silently at 3am.
for var in QBITTORRENT_USER QBITTORRENT_PASS NTFY_TOPIC NOVA_DOMAIN; do
  if ! grep -qE "^${var}=.+" "${ENV_FILE}"; then
    echo "WARNING: ${var} is unset or empty in ${ENV_FILE}" >&2
  fi
done

# ── Deploy guard script ───────────────────────────────────────────────────────

cp "${SCRIPT_DIR}/disk-space-guard.sh" /usr/local/bin/disk-space-guard.sh
chmod +x /usr/local/bin/disk-space-guard.sh

# ── Install systemd units (substitute real nova-config path) ──────────────────

sed "s|@NOVA_CONFIG_DIR@|${NOVA_CONFIG_DIR}|g" \
  "${SCRIPT_DIR}/disk-space-guard.service" \
  > /etc/systemd/system/disk-space-guard.service

cp "${SCRIPT_DIR}/disk-space-guard.timer" /etc/systemd/system/disk-space-guard.timer

# ── Enable and start ──────────────────────────────────────────────────────────

systemctl daemon-reload
systemctl enable --now disk-space-guard.timer

echo ""
echo "Done. Timer status:"
systemctl status disk-space-guard.timer --no-pager

echo ""
echo "Next run:"
systemctl list-timers disk-space-guard.timer --no-pager

echo ""
echo "Monitored mounts: / /srv/downloads /data1 /data2 /data3"
echo "     Thresholds: warn at 85% used, pause qBittorrent at 92%."
echo "     Any mount already above 92% will pause downloads on the first run."
echo "     Logs: journalctl -t disk-space-guard -f"
