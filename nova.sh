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
#   recreate  Full down, rebuild images, then up — targets whole stack or single service
#   logs      View logs (-f to follow)
#   ps        List running containers
#   health    Show containers not in a healthy state
#   config    Validate compose files
#   restart   Restart stack or single service (picks up config changes, no pull/rebuild)
#   orphans   Find all containers (running + stopped) not defined in any stack and offer to remove them
#
# Stack names: infra, authelia, media, immich, home, backup, gaming, dev, tools, movienight
# Omit stack name to apply to all stacks.
#
# Examples:
#   ./nova.sh init                  # Bootstrap: create networks + volumes before first up
#   ./nova.sh up                    # Start all stacks
#   ./nova.sh up media              # Start media stack
#   ./nova.sh logs media -f         # Follow media stack logs
#   ./nova.sh down                  # Stop all stacks
#   ./nova.sh restart media         # Restart media stack (picks up config changes)
#   ./nova.sh restart media kometa  # Restart only kometa service in media stack
#   ./nova.sh update infra          # Pull + restart infra stack
#   ./nova.sh recreate dev          # Full rebuild and restart dev stack
#   ./nova.sh recreate infra scrutiny  # Recreate only the scrutiny service in infra
#   ./nova.sh health                # Show unhealthy/starting containers
#   ./nova.sh orphans               # Find and optionally remove containers no longer in config

set -euo pipefail
cd "$(dirname "$0")"

ALL_STACKS=(infra authelia media immich home backup gaming dev tools movienight)

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

# --- Collect all container_name values defined across every stack file ---
# Returns one name per line. Relies on explicit container_name: labels (project convention).

get_defined_containers() {
  for s in "${ALL_STACKS[@]}"; do
    local file="docker-compose.${s}.yaml"
    [[ -f "$file" ]] || continue
    grep 'container_name:' "$file" \
      | sed 's/.*container_name: *"\?\([^"]*\)"\?.*/\1/'
  done
}

# --- Remove containers that would block a stack bring-up ---
# Force-removes containers whose names are declared in the compose file but are
# NOT owned by this compose project (stale, renamed, or manually created).
# Containers already tracked under the correct project are left for compose to
# handle naturally (no-op or recreate). Prevents "name already in use" errors.

remove_conflicting_containers() {
  local stack="$1"
  local file="docker-compose.${stack}.yaml"
  [[ -f "$file" ]] || return 0

  # Derive project name from the 'name:' field in the compose file
  local project_name
  project_name=$(grep '^name:' "$file" | awk '{print $2}' | tr -d '"' | head -1)
  [[ -z "$project_name" ]] && project_name="$stack"

  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    if docker inspect "$cname" &>/dev/null 2>&1; then
      local owner
      owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cname" 2>/dev/null || true)
      if [[ "$owner" != "$project_name" ]]; then
        echo "    [pre-clean] removing stale container '$cname' (owner: ${owner:-unmanaged})"
        docker rm -f "$cname" &>/dev/null
      fi
    fi
  done < <(grep 'container_name:' "$file" | sed 's/.*container_name: *"\?\([^"]*\)"\?.*/\1/')
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
        remove_conflicting_containers "$s"
        run_compose "$CMD" "$s" "$@" -d
      done
    else
      echo "==> $STACK"
      remove_conflicting_containers "$STACK"
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
        remove_conflicting_containers "$s"
        run_compose up "$s" -d "$@"
      done
    else
      echo "==> $STACK"
      run_compose pull "$STACK" "$@"
      remove_conflicting_containers "$STACK"
      run_compose up "$STACK" -d "$@"
    fi
    ;;

  recreate)
    ensure_traefik_network
    ensure_socket_proxy_network
    # Optional third argument: single service name within the stack
    SERVICE=""
    if [[ -n "${1:-}" && ! "${1:-}" =~ ^- ]]; then
      SERVICE="$1"
      shift
    fi
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s: down"
        run_compose down "$s"
        echo "==> $s: build"
        run_compose build "$s" --pull "$@"
        echo "==> $s: up"
        run_compose up "$s" -d "$@"
      done
    elif [[ -n "$SERVICE" ]]; then
      echo "==> $STACK/$SERVICE: stop"
      run_compose stop "$STACK" "$SERVICE"
      echo "==> $STACK/$SERVICE: rm"
      run_compose rm "$STACK" -f "$SERVICE"
      echo "==> $STACK/$SERVICE: build"
      run_compose build "$STACK" "$SERVICE" --pull "$@"
      echo "==> $STACK/$SERVICE: up"
      run_compose up "$STACK" -d "$SERVICE" "$@"
    else
      echo "==> $STACK: down"
      run_compose down "$STACK"
      echo "==> $STACK: build"
      run_compose build "$STACK" --pull "$@"
      echo "==> $STACK: up"
      run_compose up "$STACK" -d "$@"
    fi
    ;;

  restart)
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s"
        run_compose restart "$s" "$@"
      done
    else
      # Optional third argument: single service name within the stack
      SERVICE=""
      if [[ -n "${1:-}" && ! "${1:-}" =~ ^- ]]; then
        SERVICE="$1"
        shift
      fi
      echo "==> $STACK${SERVICE:+/$SERVICE}"
      run_compose restart "$STACK" ${SERVICE:+"$SERVICE"} "$@"
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

  orphans)
    echo "==> Scanning for all containers (running + stopped) not defined in any stack..."
    # Build lookup of defined container names
    defined=$(get_defined_containers | sort)
    all_containers=$(docker ps -a --format "{{.Names}}" | sort)

    orphan_list=()
    while IFS= read -r name; do
      if ! grep -qxF "$name" <(echo "$defined"); then
        orphan_list+=("$name")
      fi
    done <<< "$all_containers"

    if [[ ${#orphan_list[@]} -eq 0 ]]; then
      echo "No orphaned containers found."
      exit 0
    fi

    echo ""
    echo "Found ${#orphan_list[@]} container(s) not in any stack:"
    for name in "${orphan_list[@]}"; do
      image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || echo "unknown")
      status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
      printf "  %-35s  %-12s  %s\n" "$name" "$status" "$image"
    done
    echo ""

    read -rp "Stop and remove all of the above? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      for name in "${orphan_list[@]}"; do
        echo "  Stopping $name..."
        docker stop "$name" 2>/dev/null || true
        echo "  Removing $name..."
        docker rm "$name"
      done
      echo "Done."
    else
      echo "Aborted — no containers removed."
    fi
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run ./nova.sh with no args for usage." >&2
    exit 1
    ;;
esac
