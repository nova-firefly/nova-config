#!/usr/bin/env bash
# laptop-host.sh — Run a minimal subset of nova on a temporary stand-in host
# (WSL2 + Docker Engine on a small laptop) while the primary server is down.
#
# Brings up only services that are useful starting from empty volumes and whose
# state can be copied back to the primary server afterwards:
#
#   infra     socket-proxy, duckdns, traefik, homepage
#   authelia  authelia, redis
#   home      homeassistant, matter-server, music-assistant-server, zwave-js-ui
#   tools     ntfy                      (HA sends notifications through it)
#   strava-hevy                         (opt-in: --strava)
#
# Uses `docker compose` per stack instead of nova.sh: a bare `nova.sh up/update/heal`
# acts on all 13 stacks, which this host cannot hold, and tools/compose.yaml refuses
# to parse without Actual/shell vars that are irrelevant here (placeholders below).
#
# Usage: host-scripts/laptop-host.sh [command] [modifiers]
#
# Commands:
#   up        Create networks/volumes, then start the services (default)
#   down      Stop and remove the services (volumes are kept)
#   pull      Pull images for the services
#   update    pull + up
#   status    Show the selected containers and their health
#   logs      Follow logs for the selected services
#
# Modifiers:
#   --strava        Also run strava-hevy
#   --no-homepage   Skip homepage
#   --no-music      Skip music-assistant-server (saves ~300 MB RAM)
#   --no-zwave      Skip zwave-js-ui (e.g. the Zooz stick is not attached yet)
#   --dry-run       Print the docker commands instead of running them
#
# Moving back to the primary server: stop duckdns here first (`down`), then copy
# back ha_config, zwave-js-ui, matter_server_data, the Music Assistant data dir and
# (if used) strava_hevy_data. Do NOT copy authelia_data, ntfy_data or traefik_acme.

set -euo pipefail
cd "$(dirname "$0")/.."

CMD="up"
WITH_STRAVA=0
WITH_HOMEPAGE=1
WITH_MUSIC=1
WITH_ZWAVE=1
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    up|down|pull|update|status|logs) CMD="$arg" ;;
    --strava)       WITH_STRAVA=1 ;;
    --no-homepage)  WITH_HOMEPAGE=0 ;;
    --no-music)     WITH_MUSIC=0 ;;
    --no-zwave)     WITH_ZWAVE=0 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -o allexport; source .env; set +o allexport
else
  echo "Error: .env not found in $(pwd)" >&2
  exit 1
fi

for var in NOVA_DOMAIN NOVA_HOSTNAME TZ DUCKDNS_TOKEN DUCKDNS_SUBDOMAIN ACME_EMAIL; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is empty in .env" >&2
    exit 1
  fi
done

# tools/compose.yaml uses ${VAR:?} for services we never start here. Shell env takes
# precedence over the stack's .env file, so these only satisfy the parser.
export ACTUAL_PASSWORD="${ACTUAL_PASSWORD:-unused-on-laptop}"
export ACTUAL_SYNC_ID="${ACTUAL_SYNC_ID:-unused-on-laptop}"
export MCP_BEARER_TOKEN="${MCP_BEARER_TOKEN:-unused-on-laptop}"
export SHELL_SSH_USER="${SHELL_SSH_USER:-unused-on-laptop}"

# --- Selection: "stack:service service ..." in start order ---

infra_svcs="socket-proxy duckdns traefik"
(( WITH_HOMEPAGE )) && infra_svcs+=" homepage"

home_svcs="homeassistant matter-server"
(( WITH_MUSIC )) && home_svcs+=" music-assistant-server"
(( WITH_ZWAVE )) && home_svcs+=" zwave-js-ui"

PLAN=(
  "infra:${infra_svcs}"
  "authelia:authelia redis"
  "home:${home_svcs}"
  "tools:ntfy"
)
(( WITH_STRAVA )) && PLAN+=("strava-hevy:strava-hevy")

# External volumes the selected services need (pre-created, like `nova.sh init`).
VOLUMES=(traefik_acme authelia_data authelia_redis ha_config matter_server_data ntfy_data)
(( WITH_ZWAVE )) && VOLUMES+=(zwave-js-ui)
(( WITH_STRAVA )) && VOLUMES+=(strava_hevy_data)

run() {
  if (( DRY_RUN )); then
    echo "+ $*"
  else
    "$@"
  fi
}

compose() {
  local stack="$1"; shift
  run docker compose -f "${stack}/compose.yaml" "$@"
}

preflight() {
  if (( ! DRY_RUN )) && ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not reachable. Try: sudo systemctl start docker" >&2
    exit 1
  fi
  if (( WITH_ZWAVE && ! DRY_RUN )) && ! ls /dev/serial/by-id/*Zooz* >/dev/null 2>&1; then
    echo "Error: Zooz Z-Wave stick not found in /dev/serial/by-id/." >&2
    echo "       Attach it from admin PowerShell: usbipd attach --wsl --busid <BUSID> --auto-attach" >&2
    echo "       Or re-run with --no-zwave." >&2
    exit 1
  fi
  if (( WITH_MUSIC )); then
    # home/compose.yaml bind-mounts this host path; create it so Docker doesn't make it root-owned.
    run sudo mkdir -p /home/koonan/docker/music-assistant-server/data
  fi
  for net in traefik_default socket_proxy; do
    docker network inspect "$net" >/dev/null 2>&1 || run docker network create "$net"
  done
  for vol in "${VOLUMES[@]}"; do
    docker volume inspect "$vol" >/dev/null 2>&1 || run docker volume create "$vol"
  done
}

for_each() {
  # Apply a compose subcommand to every planned stack; $1=order (fwd|rev), rest=args.
  local order="$1"; shift
  local entries=("${PLAN[@]}")
  if [[ "$order" == "rev" ]]; then
    local reversed=()
    for (( i=${#entries[@]}-1; i>=0; i-- )); do reversed+=("${entries[i]}"); done
    entries=("${reversed[@]}")
  fi
  for entry in "${entries[@]}"; do
    local stack="${entry%%:*}" svcs="${entry#*:}"
    echo "==> ${stack}: ${svcs}"
    # shellcheck disable=SC2086
    compose "$stack" "$@" $svcs
  done
}

case "$CMD" in
  up)
    preflight
    for_each fwd up -d
    ;;
  down)
    for_each rev rm --stop --force
    ;;
  pull)
    for_each fwd pull
    ;;
  update)
    preflight
    for_each fwd pull
    for_each fwd up -d
    ;;
  status)
    names=()
    for entry in "${PLAN[@]}"; do
      for svc in ${entry#*:}; do
        # authelia's redis container is named authelia-redis
        [[ "$svc" == "redis" ]] && svc="authelia-redis"
        names+=(--filter "name=^${svc}$")
      done
    done
    run docker ps -a "${names[@]}" --format 'table {{.Names}}\t{{.Status}}'
    ;;
  logs)
    pids=()
    for entry in "${PLAN[@]}"; do
      stack="${entry%%:*}"
      # shellcheck disable=SC2086
      compose "$stack" logs -f --tail 50 ${entry#*:} &
      pids+=($!)
    done
    trap 'kill "${pids[@]}" 2>/dev/null' INT TERM
    wait
    ;;
esac
