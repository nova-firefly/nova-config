#!/bin/bash
# nova.sh - Manage all docker compose stacks
# Usage: ./nova.sh [--env prod|test] [command] [stack] [extra args...]
#
# Commands:
#   up        Start stack(s)
#   down      Stop stack(s)
#   pull      Pull latest images
#   update    Pull + restart stack(s)
#   logs      View logs (-f to follow)
#   ps        List running containers
#   config    Validate compose files
#   env       Show detected environment and git branch
#   init      Create external volumes and networks for the environment
#
# Options:
#   --env prod|test   Override environment (default: auto-detect from git branch)
#
# Stack names: media, immich, home, infra, backup, gaming, dev
# Omit stack name to apply to all stacks.
#
# Environment detection:
#   - Branch "main" → prod (uses docker-compose.{stack}.yaml)
#   - Any other branch → test (layers docker-compose.{stack}.test.yaml override)
#   - Override with: --env prod|test or NOVA_ENV=prod|test
#
# Examples:
#   ./nova.sh up                    # Auto-detect env, start all stacks
#   ./nova.sh --env test up media   # Force test env, start media stack
#   ./nova.sh --env test init       # Create test volumes and networks
#   ./nova.sh env                   # Show current environment
#   ./nova.sh update infra          # Pull + restart infra stack
#   ./nova.sh logs media -f         # Follow media stack logs
#   ./nova.sh down                  # Stop all stacks

set -euo pipefail
cd "$(dirname "$0")"

ALL_STACKS=(media immich home infra backup gaming dev)

# --- Volume and network definitions per stack (for init command) ---

declare -A STACK_VOLUMES
STACK_VOLUMES[media]="bazarr_config gluetun_data overseerr_config radarr_config sonarr_config tautulli_config transmission_config transmission_data"
STACK_VOLUMES[immich]="immich_immich-ml-model-cache eeba826780300f3d846b69ccaecc2f70dc9dd09cdb8ce35b3eb4462d5ee3b122"
STACK_VOLUMES[home]="ha_config zwave-js-ui"
STACK_VOLUMES[infra]="d38249258c4c2870a526afa1ff60410a6ef5c618649a43f795388a9cd0d69b12 homepage_config portainer_data"
STACK_VOLUMES[backup]="backrest_backrest_cache backrest_backrest_config backrest_backrest_data"
STACK_VOLUMES[gaming]="minecraft_data"
STACK_VOLUMES[dev]="vibe-kanban-repos"

declare -A STACK_NETWORKS
STACK_NETWORKS[media]="media"
STACK_NETWORKS[immich]="immich_default"
STACK_NETWORKS[home]="zwave_zwave"
STACK_NETWORKS[infra]="dockge_default traefik_default wud_default"
STACK_NETWORKS[backup]="backrest_default duplicati_default"
STACK_NETWORKS[gaming]=""
STACK_NETWORKS[dev]=""

# --- Environment detection ---

SAVED_NOVA_ENV="${NOVA_ENV:-}"

detect_env() {
  # Check NOVA_ENV environment variable (set before script ran)
  if [[ -n "$SAVED_NOVA_ENV" ]]; then
    echo "$SAVED_NOVA_ENV"
    return
  fi

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  if [[ "$branch" == "main" ]]; then
    echo "prod"
  else
    echo "test"
  fi
}

# --- Compose file builder ---

get_compose_args() {
  local env="$1"
  local stack="$2"
  local base_file="docker-compose.${stack}.yaml"

  if [[ ! -f "$base_file" ]]; then
    echo "Error: Stack '$stack' not found ($base_file)" >&2
    return 1
  fi

  if [[ "$env" == "test" ]]; then
    local test_file="docker-compose.${stack}.test.yaml"
    if [[ ! -f "$test_file" ]]; then
      echo "Error: Test override not found ($test_file)" >&2
      return 1
    fi
    echo "-p nova_test -f $base_file -f $test_file"
  else
    echo "-f $base_file"
  fi
}

# --- Run compose command ---

run_compose() {
  local env="$1"
  local cmd="$2"
  local stack="$3"
  shift 3

  local compose_args
  compose_args=$(get_compose_args "$env" "$stack") || return 1

  # shellcheck disable=SC2086
  docker compose $compose_args "$cmd" "$@"
}

# --- Init command: create external volumes and networks ---

init_env() {
  local env="$1"
  local stack="${2:-}"

  local stacks_to_init=()
  if [[ -n "$stack" ]]; then
    stacks_to_init=("$stack")
  else
    stacks_to_init=("${ALL_STACKS[@]}")
  fi

  local prefix=""
  if [[ "$env" == "test" ]]; then
    prefix="test_"
  fi

  for s in "${stacks_to_init[@]}"; do
    echo "==> Initializing $env volumes and networks for: $s"

    # Create volumes
    for vol in ${STACK_VOLUMES[$s]:-}; do
      local vol_name="${prefix}${vol}"
      if docker volume inspect "$vol_name" &>/dev/null; then
        echo "  Volume exists: $vol_name"
      else
        docker volume create "$vol_name"
        echo "  Created volume: $vol_name"
      fi
    done

    # Create networks
    for net in ${STACK_NETWORKS[$s]:-}; do
      local net_name="${prefix}${net}"
      if docker network inspect "$net_name" &>/dev/null; then
        echo "  Network exists: $net_name"
      else
        docker network create "$net_name"
        echo "  Created network: $net_name"
      fi
    done
  done

  echo ""
  echo "Init complete for $env environment."
}

# --- Parse --env flag ---

NOVA_ENV_OVERRIDE=""
if [[ "${1:-}" == "--env" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "Error: --env requires a value (prod or test)" >&2
    exit 1
  fi
  NOVA_ENV_OVERRIDE="$2"
  if [[ "$NOVA_ENV_OVERRIDE" != "prod" && "$NOVA_ENV_OVERRIDE" != "test" ]]; then
    echo "Error: --env must be 'prod' or 'test'" >&2
    exit 1
  fi
  shift 2
fi

# Determine environment
if [[ -n "$NOVA_ENV_OVERRIDE" ]]; then
  ENV="$NOVA_ENV_OVERRIDE"
else
  ENV=$(detect_env)
fi

export NOVA_ENV="$ENV"

# --- Show usage if no args ---

if [[ $# -lt 1 ]]; then
  head -34 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

CMD="$1"
STACK="${2:-}"
shift 1
[[ -n "$STACK" ]] && shift

# --- Handle commands ---

case "$CMD" in
  env)
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "Git branch:  $branch"
    echo "Environment: $ENV"
    if [[ -n "$NOVA_ENV_OVERRIDE" ]]; then
      echo "Source:      --env flag"
    elif [[ -n "$SAVED_NOVA_ENV" ]]; then
      echo "Source:      NOVA_ENV environment variable"
    else
      echo "Source:      auto-detected from branch"
    fi
    ;;

  init)
    init_env "$ENV" "$STACK"
    ;;

  up|down|pull|ps|config)
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s [$ENV]"
        run_compose "$ENV" "$CMD" "$s" "$@"
      done
    else
      echo "==> $STACK [$ENV]"
      run_compose "$ENV" "$CMD" "$STACK" "$@"
    fi
    ;;

  update)
    if [[ -z "$STACK" ]]; then
      for s in "${ALL_STACKS[@]}"; do
        echo "==> $s [$ENV]"
        run_compose "$ENV" pull "$s" "$@"
        run_compose "$ENV" up "$s" -d "$@"
      done
    else
      echo "==> $STACK [$ENV]"
      run_compose "$ENV" pull "$STACK" "$@"
      run_compose "$ENV" up "$STACK" -d "$@"
    fi
    ;;

  logs)
    if [[ -z "$STACK" ]]; then
      echo "Error: specify a stack for logs (e.g. ./nova.sh logs media -f)" >&2
      exit 1
    fi
    run_compose "$ENV" logs "$STACK" "$@"
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run ./nova.sh with no args for usage." >&2
    exit 1
    ;;
esac
