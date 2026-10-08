#!/usr/bin/env bash
# Wraps the upstream Paseo entrypoint to seed default plugins once.
#
# Plugins are installed through the running daemon (`paseo plugin add` is an RPC,
# not a file copy), so seeding has to happen after the daemon is up. A background
# job waits for /api/health, installs each plugin as the paseo user, and records
# a marker in the paseo_home volume. The marker makes it one-shot: uninstalling a
# seeded plugin from the app sticks, it is not reinstalled on the next boot.
# Delete the marker to re-seed.
set -euo pipefail

SEED_MARKER="/home/paseo/.paseo/.nova-plugins-seeded"
# paseo.cafe in-app plugin browser/installer. Pinned to the version paseo.cafe
# lists; the plugin updates itself afterwards.
SEED_PLUGINS=("npm:paseo-cafe@0.11.0")

seed_plugins() {
  local port="${PASEO_LISTEN##*:}"
  local i
  for i in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:${port:-6767}/api/health" >/dev/null 2>&1 && break
    sleep 5
  done

  local plugin failed=0
  for plugin in "${SEED_PLUGINS[@]}"; do
    echo "[nova] installing plugin ${plugin}"
    if ! gosu paseo paseo plugin add "$plugin"; then
      echo "[nova] WARNING: failed to install plugin ${plugin}; will retry next boot" >&2
      failed=1
    fi
  done

  if [[ "$failed" == "0" ]]; then
    gosu paseo touch "$SEED_MARKER"
  fi
}

if [[ ! -f "$SEED_MARKER" ]]; then
  seed_plugins &
fi

exec /usr/local/bin/paseo-docker-entrypoint "$@"
