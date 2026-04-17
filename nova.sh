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
#   reconcile        Check all stacks for missing containers and recreate them (self-healing)
#   secrets-refresh  Pull secrets from 1Password Connect and regenerate .env
#
# Stack names: infra, secrets, authelia, media, immich, home, backup, gaming, dev, tools, movienight, movienight-test
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
#   ./nova.sh reconcile             # Detect + recreate any missing containers across all stacks

set -euo pipefail
cd "$(dirname "$0")"

# Load .env so NOVA_DOMAIN and NTFY_TOPIC are available to the shell
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -o allexport; source .env; set +o allexport
fi

ALL_STACKS=(infra secrets authelia media immich home backup gaming dev tools movienight movienight-test)

# Stacks excluded from reconcile — intentionally transient or CI-only stacks
RECONCILE_SKIP_STACKS=(movienight-test)

# --- ntfy notification helper ---
# Publishes a push notification to ntfy when a mutating compose command runs.
# Requires NTFY_TOPIC (and NOVA_DOMAIN) to be set in .env; silently no-ops otherwise.

ntfy_notify() {
  local title="$1" body="$2" tags="$3" priority="${4:-default}"
  [[ -z "${NTFY_TOPIC:-}" || -z "${NOVA_DOMAIN:-}" ]] && return 0
  curl -sf \
    -H "Title: ${title}" \
    -H "Tags: ${tags}" \
    -H "Priority: ${priority}" \
    -d "${body}" \
    "https://ntfy.${NOVA_DOMAIN}/${NTFY_TOPIC}" \
    >/dev/null 2>&1 || true  # never let a failed notification break the script
}

# Set this variable in mutating case blocks to enable ntfy on exit.
# The trap fires on both clean exit and error, so both success and failure are covered.
_NTFY_TITLE=""

_ntfy_on_exit() {
  local rc=$?
  [[ -z "${_NTFY_TITLE:-}" ]] && return
  if [[ $rc -eq 0 ]]; then
    ntfy_notify "${_NTFY_TITLE}" "Completed $(date '+%Y-%m-%d %H:%M:%S')" "white_check_mark" "default"
  else
    ntfy_notify "${_NTFY_TITLE} FAILED" "Failed (exit ${rc}) at $(date '+%Y-%m-%d %H:%M:%S')" "warning" "high"
  fi
}
trap _ntfy_on_exit EXIT

# --- Ensure shared networks exist ---

ensure_traefik_network() {
  docker network create traefik_default 2>/dev/null || true
}

ensure_socket_proxy_network() {
  docker network create socket_proxy 2>/dev/null || true
}

ensure_internal_webhook_network() {
  # internal: true — containers on this network have no internet egress.
  # Shared between internal-webhook (media stack) and authorised caller containers.
  docker network create --internal internal_webhook 2>/dev/null || true
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
shift 1
# If next arg is present and doesn't start with '-', treat it as the stack name.
# Flags like --no-recreate are extra args passed through to docker compose, not stack names.
STACK=""
if [[ -n "${1:-}" && ! "${1:-}" =~ ^- ]]; then
  STACK="$1"
  shift
fi

# --- Handle commands ---

case "$CMD" in
  down)
    _NTFY_TITLE="nova down ${STACK:-all}"
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
    # Allow callers (e.g. nova-heal) to suppress the exit notification and handle it themselves
    [[ -z "${NOVA_SUPPRESS_NOTIFY:-}" ]] && _NTFY_TITLE="nova up ${STACK:-all}"
    ensure_traefik_network
    ensure_socket_proxy_network
    ensure_internal_webhook_network
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
    _NTFY_TITLE="nova update ${STACK:-all}"
    ensure_traefik_network
    ensure_socket_proxy_network
    ensure_internal_webhook_network
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
    _NTFY_TITLE="nova recreate ${STACK:-all}"
    ensure_traefik_network
    ensure_socket_proxy_network
    ensure_internal_webhook_network
    # Optional third argument: single service name within the stack
    SERVICE=""
    if [[ -n "${1:-}" && ! "${1:-}" =~ ^- ]]; then
      SERVICE="$1"
      shift
      _NTFY_TITLE="nova recreate ${STACK:-all}/${SERVICE}"
    fi
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s: down"
        run_compose down "$s"
        echo "==> $s: build"
        run_compose build "$s" --pull --no-cache "$@"
        echo "==> $s: up"
        run_compose up "$s" -d "$@"
      done
    elif [[ -n "$SERVICE" ]]; then
      echo "==> $STACK/$SERVICE: stop"
      run_compose stop "$STACK" "$SERVICE"
      echo "==> $STACK/$SERVICE: rm"
      run_compose rm "$STACK" -f "$SERVICE"
      echo "==> $STACK/$SERVICE: build"
      run_compose build "$STACK" "$SERVICE" --pull --no-cache "$@"
      echo "==> $STACK/$SERVICE: up"
      run_compose up "$STACK" -d "$SERVICE" "$@"
    else
      echo "==> $STACK: down"
      run_compose down "$STACK"
      echo "==> $STACK: build"
      run_compose build "$STACK" --pull --no-cache "$@"
      echo "==> $STACK: up"
      run_compose up "$STACK" -d "$@"
    fi
    ;;

  restart)
    _NTFY_TITLE="nova restart ${STACK:-all}"
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
        _NTFY_TITLE="nova restart ${STACK}/${SERVICE}"
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
    ensure_internal_webhook_network
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

  reconcile)
    echo "==> Reconcile: checking all stacks for missing containers ($(date '+%Y-%m-%d %H:%M:%S'))..."
    ensure_traefik_network
    ensure_socket_proxy_network
    ensure_internal_webhook_network

    recovered_stacks=()

    for s in "${ALL_STACKS[@]}"; do
      # Skip intentionally transient/CI stacks
      [[ " ${RECONCILE_SKIP_STACKS[*]} " == *" ${s} "* ]] && {
        printf "  [skip] %s\n" "$s"
        continue
      }

      file="docker-compose.${s}.yaml"
      [[ -f "$file" ]] || continue

      # Derive the compose project name (matches com.docker.compose.project label)
      project_name=$(grep '^name:' "$file" | awk '{print $2}' | tr -d '"' | head -1)
      [[ -z "$project_name" ]] && project_name="$s"

      # Get services defined in this stack
      mapfile -t services < <(docker compose -f "$file" config --services 2>/dev/null || true)
      [[ ${#services[@]} -eq 0 ]] && continue

      missing_services=()
      for svc in "${services[@]}"; do
        # Check whether ANY container exists (running or stopped) for this service
        existing=$(docker ps -a \
          --filter "label=com.docker.compose.project=${project_name}" \
          --filter "label=com.docker.compose.service=${svc}" \
          --format "{{.Names}}" 2>/dev/null | head -1)
        [[ -z "$existing" ]] && missing_services+=("$svc")
      done

      if [[ ${#missing_services[@]} -gt 0 ]]; then
        echo "  [MISSING] ${s}: ${missing_services[*]}"
        remove_conflicting_containers "$s"
        if run_compose up "$s" -d; then
          recovered_stacks+=("${s}(${missing_services[*]})")
        else
          echo "  [ERROR]   ${s}: compose up -d failed — manual intervention may be needed"
          ntfy_notify \
            "nova reconcile: FAILED ${s}" \
            "compose up -d failed for ${s}. Missing: ${missing_services[*]}" \
            "warning" \
            "urgent"
        fi
      else
        printf "  [ok]  %s\n" "$s"
      fi
    done

    echo ""
    if [[ ${#recovered_stacks[@]} -gt 0 ]]; then
      recovered_str=$(printf '%s, ' "${recovered_stacks[@]}")
      recovered_str="${recovered_str%, }"
      echo "==> Self-healed: ${recovered_str}"
      ntfy_notify \
        "nova self-heal: containers recovered" \
        "Recreated missing containers: ${recovered_str}" \
        "ambulance,white_check_mark" \
        "high"
    else
      echo "==> All stacks healthy — no recovery needed."
    fi
    ;;

  secrets-refresh)
    # Pull secrets from 1Password Connect and regenerate .env.
    # Runs the op CLI in a disposable container — no host install required.
    if [[ -z "${OP_CONNECT_TOKEN:-}" ]]; then
      echo "Error: OP_CONNECT_TOKEN not set in .env" >&2
      exit 1
    fi
    if [[ ! -f ".env.tpl" ]]; then
      echo "Error: .env.tpl not found" >&2
      exit 1
    fi
    echo "==> Refreshing .env from 1Password Connect (http://localhost:8080)..."
    [[ -f ".env" ]] && cp ".env" ".env.backup"
    docker run --rm \
      --network host \
      -v "$(pwd)/.env.tpl:/app/.env.tpl:ro" \
      -e OP_CONNECT_HOST="http://localhost:8080" \
      -e OP_CONNECT_TOKEN="${OP_CONNECT_TOKEN}" \
      1password/op:2 \
      inject -i /app/.env.tpl > .env
    echo "==> Done. Restart affected stacks to apply new values:"
    echo "    ./nova.sh restart <stack>"
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run ./nova.sh with no args for usage." >&2
    exit 1
    ;;
esac
