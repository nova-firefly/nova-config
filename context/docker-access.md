# Docker Socket Access Policy

All containers that need Docker API access connect through `socket-proxy`
(`tecnativa/docker-socket-proxy` in `docker-compose.infra.yaml`), not directly to
`/var/run/docker.sock`. The vibe-kanban container is no exception — it uses
`DOCKER_HOST=tcp://socket-proxy:2375`.

## What the Proxy Permits (Read-Only GET endpoints)

| Proxy env var | Docker API path | Allowed CLI commands |
|---|---|---|
| `CONTAINERS=1` | `GET /containers/*` | `docker ps [-a]`, `docker inspect <ctr>`, `docker top`, `docker stats` |
| `LOGS=1` | `GET /containers/{id}/logs` | `docker logs <ctr>` |
| `EVENTS=1` | `GET /events` | `docker events` |
| `INFO=1` | `GET /info` | `docker info` |
| `VERSION=1` | `GET /version` | `docker version` |
| `NETWORKS=1` | `GET /networks/*` | `docker network ls`, `docker network inspect <net>` |
| `VOLUMES=1` | `GET /volumes/*` | `docker volume ls`, `docker volume inspect <vol>` |

`docker compose ps` and `docker compose logs` also work (they use the same GET endpoints).

## What Is Blocked

Everything not listed above is blocked — either because the endpoint group defaults to `0`,
or because all POST/DELETE methods are disabled by default.

| Category | Blocked commands |
|---|---|
| Container lifecycle | `docker run`, `docker create`, `docker start`, `docker stop`, `docker restart`, `docker kill`, `docker rm`, `docker pause`, `docker unpause` |
| Exec | `docker exec` |
| Images | `docker images`, `docker pull`, `docker build`, `docker rmi`, `docker tag`, `docker push` |
| Networks (write) | `docker network create`, `docker network rm`, `docker network connect`, `docker network disconnect` |
| Volumes (write) | `docker volume create`, `docker volume rm` |
| Compose (write) | `docker compose up`, `docker compose down`, `docker compose pull`, `docker compose restart`, `docker compose build` |

## Design Rationale

- **Read-only observation** is the intended use case: Claude and other tools can inspect
  running containers, tail logs, and enumerate networks/volumes, but cannot mutate
  infrastructure.
- Stack management (`nova.sh up/down/pull`) must be run on the **host**, not from inside
  the vibe-kanban container.
- Services that need full socket access (Arcane, WUD) mount `/var/run/docker.sock` directly
  and do **not** go through the proxy — they are explicitly excluded from this policy.

## Proxy Source

`docker-compose.infra.yaml` → `socket-proxy` service (image: `tecnativa/docker-socket-proxy`).
The proxy listens on `tcp://socket-proxy:2375` within the `socket_proxy` network, and also on
`127.0.0.1:2375` on the host loopback for host-networked services (Glances, volume-sharer).
