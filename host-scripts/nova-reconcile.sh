#!/usr/bin/env bash
# nova-reconcile.sh — Self-healing: detect and recreate missing Docker containers.
#
# Deploy:
#   sudo cp nova-reconcile.sh /usr/local/bin/nova-reconcile.sh
#   sudo chmod +x /usr/local/bin/nova-reconcile.sh
#
# Reads NOVA_CONFIG_PATH from NOVA_ENV_FILE (defaults to ~/nova-config/.env).
# Override at runtime: NOVA_ENV_FILE=/path/to/.env nova-reconcile.sh

set -euo pipefail

NOVA_ENV_FILE="${NOVA_ENV_FILE:-${HOME}/nova-config/.env}"

if [[ -f "${NOVA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${NOVA_ENV_FILE}"; set +o allexport
fi

# NOVA_CONFIG_PATH should be set in .env; defaults to ~/nova-config
NOVA_DIR="${NOVA_CONFIG_PATH:-${HOME}/nova-config}"

exec "${NOVA_DIR}/nova.sh" reconcile
