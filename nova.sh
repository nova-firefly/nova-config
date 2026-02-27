#!/bin/bash
# nova.sh - Manage all docker compose stacks
# Usage: ./nova.sh [command] [stack] [extra args...]
#
# Commands:
#   up        Start stack(s)
#   down      Stop stack(s)
#   pull      Pull latest images
#   update    Pull + restart stack(s)
#   logs      View logs (-f to follow)
#   ps        List running containers
#   config    Validate compose files
#
# Stack names: infra, media, immich, home, backup, gaming, dev, tools
# Omit stack name to apply to all stacks.
#
# Examples:
#   ./nova.sh up                    # Start all stacks
#   ./nova.sh up media              # Start media stack
#   ./nova.sh logs media -f         # Follow media stack logs
#   ./nova.sh down                  # Stop all stacks
#   ./nova.sh update infra          # Pull + restart infra stack

set -euo pipefail
cd "$(dirname "$0")"

ALL_STACKS=(infra media immich home backup gaming dev tools)

# --- Ensure traefik network exists ---

ensure_traefik_network() {
  docker network create traefik_default 2>/dev/null || true
}

# --- Compose file builder ---

get_compose_args() {
  local stack="$1"
  local base_file="docker-compose.${stack}.yaml"

  if [[ ! -f "$base_file" ]]; then
    echo "Error: Stack '$stack' not found ($base_file)" >&2
    return 1
  fi

  echo "-f $base_file"
}

# --- Run compose command ---

run_compose() {
  local cmd="$1"
  local stack="$2"
  shift 2

  local compose_args
  compose_args=$(get_compose_args "$stack") || return 1

  # shellcheck disable=SC2086
  docker compose $compose_args "$cmd" "$@"
}

# --- Show usage if no args ---

if [[ $# -lt 1 ]]; then
  head -22 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

CMD="$1"
STACK="${2:-}"
shift 1
[[ -n "$STACK" ]] && shift

# --- Handle commands ---

case "$CMD" in
  down)
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose down "$s" "$@"
      done
    else
      echo "==> $STACK"
      run_compose down "$STACK" "$@"
    fi
    ;;

  up)
    ensure_traefik_network
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose "$CMD" "$s" "$@"
      done
    else
      echo "==> $STACK"
      run_compose "$CMD" "$STACK" "$@"
    fi
    ;;

  pull|ps|config)
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose "$CMD" "$s" "$@"
      done
    else
      echo "==> $STACK"
      run_compose "$CMD" "$STACK" "$@"
    fi
    ;;

  update)
    ensure_traefik_network
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose pull "$s" "$@"
        run_compose up "$s" -d "$@"
      done
    else
      echo "==> $STACK"
      run_compose pull "$STACK" "$@"
      run_compose up "$STACK" -d "$@"
    fi
    ;;

  logs)
    if [[ -z "$STACK" ]]; then
      echo "Error: specify a stack for logs (e.g. ./nova.sh logs media -f)" >&2
      exit 1
    fi
    run_compose logs "$STACK" "$@"
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run ./nova.sh with no args for usage." >&2
    exit 1
    ;;
esac
