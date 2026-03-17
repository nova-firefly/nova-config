#!/bin/bash
# nova.sh - Manage all docker compose stacks
# Usage: ./nova.sh [command] [stack] [extra args...]
#
# Commands:
#   init      Create required networks and external volumes (run once before first up)
#   up        Start stack(s)
#   down      Stop stack(s)
#   pull      Pull latest images
#   update    Pull + restart stack(s)
#   recreate  Full down, rebuild images, then up — guarantees all changes applied
#   logs      View logs (-f to follow)
#   ps        List running containers
#   health    Show containers not in a healthy state
#   config    Validate compose files
#
# Stack names: infra, media, immich, home, backup, gaming, dev, tools, movienight
# Omit stack name to apply to all stacks.
#
# Examples:
#   ./nova.sh init                  # Bootstrap: create networks + volumes before first up
#   ./nova.sh up                    # Start all stacks
#   ./nova.sh up media              # Start media stack
#   ./nova.sh logs media -f         # Follow media stack logs
#   ./nova.sh down                  # Stop all stacks
#   ./nova.sh update infra          # Pull + restart infra stack
#   ./nova.sh recreate dev          # Full rebuild and restart dev stack
#   ./nova.sh health                # Show unhealthy/starting containers

set -euo pipefail
cd "$(dirname "$0")"

ALL_STACKS=(infra media immich home backup gaming dev tools movienight)

# --- Ensure shared networks exist ---

ensure_traefik_network() {
  docker network create traefik_default 2>/dev/null || true
}

ensure_socket_proxy_network() {
  docker network create socket_proxy 2>/dev/null || true
}

# --- Extract external volume names from a compose file ---
# Scans for volumes blocks and prints keys that have external: true beneath them.

get_external_volumes() {
  local file="$1"
  awk '
    /^volumes:/ { in_volumes=1; next }
    in_volumes && /^[a-zA-Z]/ { in_volumes=0 }
    in_volumes && /^  [a-zA-Z_-]/ { gsub(/:/, "", $1); current=$1 }
    in_volumes && /external: true/ { print current }
  ' "$file"
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
  head -30 "$0" | grep '^#' | sed 's/^# \?//'
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

  init)
    echo "==> Creating shared networks..."
    ensure_traefik_network
    ensure_socket_proxy_network
    echo "==> Creating external volumes for all stacks..."
    for s in "${ALL_STACKS[@]}"; do
      file="docker-compose.${s}.yaml"
      [[ ! -f "$file" ]] && continue
      while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        if docker volume inspect "$vol" &>/dev/null; then
          echo "    [exists]  $vol"
        else
          docker volume create "$vol"
          echo "    [created] $vol"
        fi
      done < <(get_external_volumes "$file")
    done
    echo "==> Init complete. Run ./nova.sh up to start all stacks."
    ;;

  health)
    echo "==> Container health overview ($(date '+%Y-%m-%d %H:%M:%S')):"
    echo ""
    # Show all containers with health status; flag non-healthy ones
    docker ps --format "{{.Names}}\t{{.Status}}" | sort | while IFS=$'\t' read -r name status; do
      if [[ "$status" == *"(healthy)"* ]]; then
        printf "  %-40s %s\n" "$name" "$status"
      else
        printf "  %-40s %s  <--\n" "$name" "$status"
      fi
    done
    echo ""
    # Summary of non-healthy containers
    unhealthy=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" | sort)
    starting=$(docker ps --filter "health=starting" --format "{{.Names}}" | sort)
    [[ -n "$unhealthy" ]] && echo "UNHEALTHY: $unhealthy"
    [[ -n "$starting"  ]] && echo "STARTING:  $starting"
    [[ -z "$unhealthy" && -z "$starting" ]] && echo "All containers with healthchecks are healthy."
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run ./nova.sh with no args for usage." >&2
    exit 1
    ;;
esac
