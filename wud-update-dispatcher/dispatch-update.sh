#!/bin/sh
# Dispatches a docker compose update for a single container.
# Called by the webhook server when the WUD "Install" button is clicked.
#
# Environment variables (set by hooks.json from WUD payload):
#   CONTAINER_NAME  - Docker container name (e.g. "homeassistant", "traefik-traefik-1")
#   IMAGE_NAME      - Image name (e.g. "ghcr.io/home-assistant/home-assistant")
#   CURRENT_TAG     - Currently running tag
#   LATEST_TAG      - New tag to update to

set -e

COMPOSE_DIR="/compose"

log() {
    echo "[wud-update-dispatcher] $*"
}

if [ -z "$CONTAINER_NAME" ]; then
    log "ERROR: CONTAINER_NAME not set"
    exit 1
fi

log "Update requested: $CONTAINER_NAME ($CURRENT_TAG -> $LATEST_TAG)"

# Map container name to compose file and service name.
# Container name is the value of container_name: in the compose file.
case "$CONTAINER_NAME" in
    traefik-traefik-1)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.infra.yaml"
        SERVICE="traefik-traefik-1"
        ;;
    portainer)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.infra.yaml"
        SERVICE="portainer"
        ;;
    homeassistant)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.home.yaml"
        SERVICE="homeassistant"
        ;;
    music-assistant-server)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.home.yaml"
        SERVICE="music-assistant-server"
        ;;
    zwave-js-ui)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.home.yaml"
        SERVICE="zwave-js-ui"
        ;;
    plex)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.media.yaml"
        SERVICE="plex"
        ;;
    minecraft)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.gaming.yaml"
        SERVICE="minecraft"
        ;;
    immich_server)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.immich.yaml"
        SERVICE="immich-server"
        ;;
    immich_machine_learning)
        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.immich.yaml"
        SERVICE="immich-machine-learning"
        ;;
    *)
        log "ERROR: Unknown container '$CONTAINER_NAME' - no stack mapping defined"
        exit 1
        ;;
esac

if [ ! -f "$COMPOSE_FILE" ]; then
    log "ERROR: Compose file not found: $COMPOSE_FILE"
    exit 1
fi

log "Running: docker compose -f $COMPOSE_FILE up -d $SERVICE"
docker compose -f "$COMPOSE_FILE" up -d "$SERVICE"

log "Done: $CONTAINER_NAME updated to $LATEST_TAG"
