#!/bin/bash
# nova.sh - Manage all docker compose stacks
# Usage: ./nova.sh [command] [stack] [extra args...]
#
# Commands:
#   up        Start stack(s)
#   down      Stop stack(s)
#   pull      Pull latest images
#   update    Pull + restart stack(s)
#   recreate  Full down, rebuild images, then up — guarantees all changes applied
#   logs      View logs (-f to follow)
#   ps        List running containers
#   config    Validate compose files
#
# Stack names: infra, media, immich, home, backup, gaming, dev, tools, movienight
# Omit stack name to apply to all stacks.
#
# Examples:
#   ./nova.sh up                    # Start all stacks
#   ./nova.sh up media              # Start media stack
#   ./nova.sh logs media -f         # Follow media stack logs
#   ./nova.sh down                  # Stop all stacks
#   ./nova.sh update infra          # Pull + restart infra stack
#   ./nova.sh recreate dev          # Full rebuild and restart dev stack

set -euo pipefail
cd "$(dirname "$0")"

ALL_STACKS=(infra media immich home backup gaming dev tools movienight)

# --- Per-stack Docker Compose profile activation ---
# Stacks listed here will pass --profile <value> to every compose invocation.
# Used for submodule stacks whose upstream compose uses profiles to gate services.
declare -A STACK_PROFILES
STACK_PROFILES[movienight]="production"

# --- Ensure shared networks exist ---

ensure_traefik_network() {
  docker network create traefik_default 2>/dev/null || true
}

ensure_socket_proxy_network() {
  docker network create socket_proxy 2>/dev/null || true
}

# --- Compose file builder ---

get_compose_args() {
  local stack="$1"
  local base_file="docker-compose.${stack}.yaml"

  if [[ ! -f "$base_file" ]]; then
    echo "Error: Stack '$stack' not found ($base_file)" >&2
    return 1
  fi

  # If a submodule directory exists with its own compose file, prepend it.
  # The nova override file ($base_file) then deep-merges on top, adding only
  # nova-specific labels and any services absent from the upstream file.
  local submodule_compose=""
  if [[ -d "$stack" ]]; then
    if [[ -f "${stack}/docker-compose.yaml" ]]; then
      submodule_compose="${stack}/docker-compose.yaml"
    elif [[ -f "${stack}/docker-compose.yml" ]]; then
      submodule_compose="${stack}/docker-compose.yml"
    fi
  fi

  if [[ -n "$submodule_compose" ]]; then
    echo "-f $submodule_compose -f $base_file"
  else
    echo "-f $base_file"
  fi
}

# --- Run compose command ---

run_compose() {
  local cmd="$1"
  local stack="$2"
  shift 2

  local compose_args
  compose_args=$(get_compose_args "$stack") || return 1

  # Activate a compose profile if one is configured for this stack
  local profile_args=""
  if [[ -n "${STACK_PROFILES[$stack]+x}" ]]; then
    profile_args="--profile ${STACK_PROFILES[$stack]}"
  fi

  # --project-directory ensures .env is always loaded from nova-config/ regardless
  # of which compose file is first (submodule stacks would otherwise default to the
  # submodule directory, missing the .env file entirely).
  # shellcheck disable=SC2086
  docker compose --project-directory . $compose_args $profile_args "$cmd" "$@"
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
    ensure_socket_proxy_network
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose "$CMD" "$s" "$@" -d
      done
    else
      echo "==> $STACK"
      run_compose "$CMD" "$STACK" "$@" -d
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
    ensure_socket_proxy_network
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

  recreate)
    ensure_traefik_network
    ensure_socket_proxy_network
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s: down"
        run_compose down "$s"
        echo "==> $s: build"
        run_compose build "$s" --pull "$@"
        echo "==> $s: up"
        run_compose up "$s" -d "$@"
      done
    else
      echo "==> $STACK: down"
      run_compose down "$STACK"
      echo "==> $STACK: build"
      run_compose build "$STACK" --pull "$@"
      echo "==> $STACK: up"
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
