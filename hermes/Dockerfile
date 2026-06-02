# Nova wrapper around NousResearch/hermes-agent.
#
# Adds the Docker CLI so Hermes can shell out to `docker ps`, `docker logs`,
# `docker inspect`, etc. against the read-only socket-proxy (DOCKER_HOST=tcp://socket-proxy:2375).
# Upstream image does not ship docker.
#
# Build order (see hermes/build.sh):
#   1. Build upstream as `hermes-agent:upstream` from the GitHub repo.
#   2. Build this wrapper as `hermes-nova:latest` on top of it.
#
# Both steps run before `./nova.sh up hermes`.

FROM hermes-agent:upstream

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

USER hermes
