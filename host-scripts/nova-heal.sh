#!/usr/bin/env bash
# nova-heal.sh — Periodic self-healing wrapper for nova docker stacks.
# Deployed to /usr/local/bin/ by host-scripts/install-nova-heal.sh.
#
# Runs nova.sh up --no-recreate and notifies ntfy only when containers are
# actually started/created, or when the run fails. Silent on healthy no-op runs.
# --no-recreate ensures running containers are never touched even if compose
# config has drifted — only stopped or missing containers are recovered.

set -euo pipefail

NOVA_CONFIG_DIR="@NOVA_CONFIG_DIR@"   # substituted at install time
NOVA_SH="${NOVA_CONFIG_DIR}/nova.sh"

# Source .env for NOVA_DOMAIN and NTFY_TOPIC
if [[ -f "${NOVA_CONFIG_DIR}/.env" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "${NOVA_CONFIG_DIR}/.env"; set +o allexport
fi

NOVA_DOMAIN="${NOVA_DOMAIN:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [nova-heal] $*"; }

ntfy() {
  local title="$1" body="$2" tags="$3" priority="${4:-default}"
  [[ -z "${NTFY_TOPIC}" || -z "${NOVA_DOMAIN}" ]] && return 0
  curl -sf \
    -H "Title: ${title}" \
    -H "Tags: ${tags}" \
    -H "Priority: ${priority}" \
    -d "${body}" \
    "https://ntfy.${NOVA_DOMAIN}/${NTFY_TOPIC}" \
    >/dev/null 2>&1 || true
}

TMPLOG=$(mktemp)
trap 'rm -f "${TMPLOG}"' EXIT

log "Heal run starting"

# Run nova.sh up with NOVA_SUPPRESS_NOTIFY=1 so it skips its own exit notification.
# We handle ntfy here with smarter signal: only fire when something was actually healed.
set +o pipefail
NOVA_SUPPRESS_NOTIFY=1 "${NOVA_SH}" up --no-recreate 2>&1 | tee "${TMPLOG}"
RC=${PIPESTATUS[0]}
set -o pipefail

if [[ ${RC} -ne 0 ]]; then
  log "FAILED (exit ${RC})"
  ntfy "Nova Heal FAILED" \
    "nova.sh up exited ${RC} at $(date '+%Y-%m-%d %H:%M:%S') — check: journalctl -u nova-heal" \
    "rotating_light" "high"
  exit ${RC}
fi

# docker compose up -d output marks acted-on containers as "Started" or "Created".
# Containers already running show "Running" — those we ignore.
HEALED=$(grep -E '\s+(Started|Created)\s*$' "${TMPLOG}" | sed 's/^[[:space:]]*//' || true)

if [[ -n "${HEALED}" ]]; then
  COUNT=$(echo "${HEALED}" | wc -l | tr -d ' ')
  NAMES=$(echo "${HEALED}" | awk '{print $2}' | head -10 | tr '\n' ', ' | sed 's/,$//')
  log "Recovered ${COUNT} container(s): ${NAMES}"
  ntfy "Nova Heal — ${COUNT} container(s) recovered" \
    "${NAMES}" \
    "white_check_mark" "default"
else
  log "All containers healthy — no action needed"
fi
