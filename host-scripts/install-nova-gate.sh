#!/usr/bin/env bash
# install-nova-gate.sh — Let claude-dev run nova.sh on the host, and nothing else.
#
# Run from the host's live nova-config checkout, as your normal user through sudo:
#   sudo ./host-scripts/install-nova-gate.sh
# claude-dev must be running: its networks and config volume are read off the container.
#
# What it does (idempotent — re-run after changing claude-dev's networks):
#   - Deploys nova-gate.sh to /usr/local/bin/nova-gate (root-owned, real nova-config path)
#   - Generates claude-dev's key into its config volume, <volume>/nova-gate/id_ed25519,
#     if there isn't one. The private key never exists anywhere else.
#   - Pins that key in ~$SUDO_USER/.ssh/authorized_keys to the forced command, with
#     `restrict` (no pty, no forwarding) and `from=` limited to claude-dev's subnets
#   - Writes the host's SSH host keys and an ssh_config into the same directory, so the
#     container checks the host key strictly instead of trusting on first use
#
# From claude-dev afterwards:  nova ps dev
#
# Rotate the key:  sudo ./host-scripts/install-nova-gate.sh --rotate
# Uninstall:
#   sed -i '/ claude-dev-nova-gate$/d' ~/.ssh/authorized_keys
#   sudo rm /usr/local/bin/nova-gate
#   sudo rm -r "$(docker volume inspect -f '{{.Mountpoint}}' dev_claude-dev-claude)/nova-gate"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOVA_CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NOVA_SH="${NOVA_CONFIG_DIR}/nova.sh"
CONTAINER="claude-dev"
KEY_TAG="claude-dev-nova-gate"
GATE_BIN="/usr/local/bin/nova-gate"
# Where the volume is mounted INSIDE the container — ssh_config paths must use this.
IN_CONTAINER_DIR="/root/.claude/nova-gate"

ROTATE=0
[[ "${1:-}" == "--rotate" ]] && ROTATE=1

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

# The account whose authorized_keys gets the key, and so the one nova.sh runs as.
GATE_USER="${NOVA_GATE_USER:-${SUDO_USER:-}}"
if [[ -z "${GATE_USER}" || "${GATE_USER}" == "root" ]]; then
  echo "ERROR: run via sudo from your normal user, or set NOVA_GATE_USER=<user>" >&2
  exit 1
fi
if ! id -nG "${GATE_USER}" | tr ' ' '\n' | grep -qx docker; then
  echo "ERROR: ${GATE_USER} is not in the docker group, so nova.sh cannot run as them" >&2
  exit 1
fi

if [[ ! -x "${NOVA_SH}" ]]; then
  echo "ERROR: nova.sh not found or not executable at ${NOVA_SH}" >&2
  exit 1
fi

VOLUME_DIR="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/root/.claude"}}{{.Source}}{{end}}{{end}}' "${CONTAINER}" 2>/dev/null || true)"
if [[ -z "${VOLUME_DIR}" || ! -d "${VOLUME_DIR}" ]]; then
  echo "ERROR: ${CONTAINER} is not running (or has no /root/.claude volume). Start the dev stack first." >&2
  exit 1
fi

# Every subnet claude-dev sits on. Its source address depends on which network the route
# to the host goes out of, so all of them are allowed — and nothing else.
SUBNETS=""
for net in $(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "${CONTAINER}"); do
  for sn in $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${net}"); do
    SUBNETS="${SUBNETS:+${SUBNETS},}${sn}"
  done
done
if [[ -z "${SUBNETS}" ]]; then
  echo "ERROR: could not determine ${CONTAINER}'s subnets" >&2
  exit 1
fi

echo "Installing nova-gate: nova-config ${NOVA_CONFIG_DIR}, user ${GATE_USER}, from=${SUBNETS}"

# ── Forced command ────────────────────────────────────────────────────────────

sed "s|@NOVA_CONFIG_DIR@|${NOVA_CONFIG_DIR}|g" "${SCRIPT_DIR}/nova-gate.sh" > "${GATE_BIN}"
chown root:root "${GATE_BIN}"
chmod 0755 "${GATE_BIN}"

# ── Key, host keys and ssh_config, inside claude-dev's volume ─────────────────

GATE_DIR="${VOLUME_DIR}/nova-gate"
install -d -m 0700 "${GATE_DIR}"

if [[ ${ROTATE} -eq 1 || ! -f "${GATE_DIR}/id_ed25519" ]]; then
  rm -f "${GATE_DIR}/id_ed25519" "${GATE_DIR}/id_ed25519.pub"
  ssh-keygen -q -t ed25519 -N '' -C "${KEY_TAG}" -f "${GATE_DIR}/id_ed25519"
  echo "Generated a new key in ${GATE_DIR}"
fi

# Host keys under the alias `nova`, matched through HostKeyAlias below, so the check does
# not depend on which address the container dials.
for f in /etc/ssh/ssh_host_*_key.pub; do
  printf 'nova %s\n' "$(cut -d' ' -f1,2 "$f")"
done > "${GATE_DIR}/known_hosts"

cat > "${GATE_DIR}/ssh_config" <<EOF
# Written by host-scripts/install-nova-gate.sh — re-run that instead of editing this.
Host nova
  HostName host.docker.internal
  User ${GATE_USER}
  HostKeyAlias nova
  IdentityFile ${IN_CONTAINER_DIR}/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ${IN_CONTAINER_DIR}/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  RequestTTY no
  ConnectTimeout 5
  ServerAliveInterval 30
  LogLevel ERROR
EOF

# ── authorized_keys ───────────────────────────────────────────────────────────

USER_HOME="$(getent passwd "${GATE_USER}" | cut -d: -f6)"
USER_GROUP="$(id -gn "${GATE_USER}")"
AK="${USER_HOME}/.ssh/authorized_keys"
install -d -m 0700 -o "${GATE_USER}" -g "${USER_GROUP}" "${USER_HOME}/.ssh"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
# Drop any previous entry (e.g. before --rotate), then add the current one.
if [[ -f "${AK}" ]]; then
  grep -v " ${KEY_TAG}\$" "${AK}" > "${TMP}" || true
fi
printf 'restrict,from="%s",command="%s" %s\n' \
  "${SUBNETS}" "${GATE_BIN}" "$(cat "${GATE_DIR}/id_ed25519.pub")" >> "${TMP}"
install -m 0600 -o "${GATE_USER}" -g "${USER_GROUP}" "${TMP}" "${AK}"

echo ""
echo "Done. From claude-dev:  nova ps dev"
echo "Audit trail:            journalctl -t nova-gate"

# The gate is pointless if another key in the same file is a general-purpose login that
# claude-dev can get hold of — which is exactly what the old ~/.ssh mount allowed.
UNRESTRICTED="$(grep -vE '^[[:space:]]*(#|$)' "${AK}" | grep -v 'command=' | awk '{print $NF}' || true)"
if [[ -n "${UNRESTRICTED}" ]]; then
  echo ""
  echo "WARNING: ${AK} also has keys with no forced command:"
  echo "${UNRESTRICTED}" | sed 's/^/  - /'
  echo "Make sure none of their private keys are reachable from any container."
fi
