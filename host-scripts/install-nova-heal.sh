#!/usr/bin/env bash
# install-nova-heal.sh — Install the nova self-healing systemd timer on the host.
#
# Run once as root from anywhere in the nova-config repo:
#   sudo ./host-scripts/install-nova-heal.sh
#
# What it does:
#   - Installs nova-heal.service (calls nova.sh up) to /etc/systemd/system/
#   - Installs nova-heal.timer (fires every 3 hours) to /etc/systemd/system/
#   - Enables and starts the timer
#
# To uninstall:
#   sudo systemctl disable --now nova-heal.timer
#   sudo rm /etc/systemd/system/nova-heal.{service,timer}
#   sudo systemctl daemon-reload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOVA_CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NOVA_SH="${NOVA_CONFIG_DIR}/nova.sh"

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

if [[ ! -x "${NOVA_SH}" ]]; then
  echo "ERROR: nova.sh not found or not executable at ${NOVA_SH}" >&2
  exit 1
fi

echo "Installing nova-heal using nova-config at: ${NOVA_CONFIG_DIR}"

# ── Write service file (substitute real path) ─────────────────────────────────

sed "s|@NOVA_CONFIG_DIR@|${NOVA_CONFIG_DIR}|g" \
  "${SCRIPT_DIR}/nova-heal.service" \
  > /etc/systemd/system/nova-heal.service

# ── Copy timer file ───────────────────────────────────────────────────────────

cp "${SCRIPT_DIR}/nova-heal.timer" /etc/systemd/system/nova-heal.timer

# ── Enable and start ──────────────────────────────────────────────────────────

systemctl daemon-reload
systemctl enable --now nova-heal.timer

echo ""
echo "Done. Timer status:"
systemctl status nova-heal.timer --no-pager

echo ""
echo "Next run:"
systemctl list-timers nova-heal.timer --no-pager
