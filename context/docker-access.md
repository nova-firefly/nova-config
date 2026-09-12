# Docker Socket Access Policy

All containers that need Docker API access connect through `socket-proxy`
(`tecnativa/docker-socket-proxy` in `infra/compose.yaml`), not directly to
`/var/run/docker.sock`. The dev container is no exception —
`claude-dev` uses `DOCKER_HOST=tcp://socket-proxy:2375`.

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
  the `claude-dev` container. It cannot *run* `nova.sh`, but it can *read* what
  it did — see "nova.sh run logs" below. It also has no SSH route to the host — see
  "No Host SSH" below.
- Services that need full socket access (Arcane, WUD) mount `/var/run/docker.sock` directly
  and do **not** go through the proxy — they are explicitly excluded from this policy.

## No Host SSH

The proxy is only a boundary if nothing else reaches the host. Host sshd **is** reachable
from `claude-dev` (bridge gateway, `172.18.0.1:22`), so the container must hold no key the
host accepts.

It used to: `dev/compose.yaml` mounted the host's `~/.ssh` read-only for git-over-SSH, and
that directory held a pre-runner-era deploy key listed in koonan's `authorized_keys` with no
restrictions. That was a working shell as koonan — `docker`, `sudo` and `lxd` groups, i.e.
root-equivalent — which made the read-only proxy moot. The mount was removed.

Git now uses HTTPS only. `GH_TOKEN` authenticates through the `gh auth git-credential`
helper in the mounted `.gitconfig`, and `GIT_CONFIG_*` env vars rewrite `git@github.com:`
remotes to `https://github.com/` inside this container only — the checkouts in `/repos`
keep their SSH remotes because the volume is shared with kandev. Nothing needs changing
per repo; `git push` just works.

Do not re-add `~/.ssh` (or any key) to this container. If it ever needs to act on the host,
give it a dedicated key that the host pins to a forced command (`restrict,command=...` in
`authorized_keys`), never a general-purpose login.

## Volume Access (Read-Only)

`claude-dev` has **read-only** access to the contents of every named Docker volume on the
host. This is useful for inspecting application logs, config files, and on-disk state
directly without needing `docker exec` (which the proxy blocks).

| Container | Mount | Path to contents |
|---|---|---|
| `claude-dev` | one bind: `/var/lib/docker/volumes:/mnt/volumes:ro` | `/mnt/volumes/<volume>/`**`_data`**`/<path>` |

### How it works — a single bind

One read-only bind of the host's Docker volume root, following the same precedent as
`volume-sharer` in `infra/compose.yaml`. Nothing to maintain: volumes created in future are
covered automatically, and adding a stack never requires editing `dev/compose.yaml`.

Because this exposes Docker's on-disk layout rather than the volumes themselves, contents sit
under a `_data` subdirectory:

```bash
tail -f /mnt/volumes/radarr_config/_data/logs/radarr.txt
ls /mnt/volumes/                      # every volume on the host
```

**Torrent downloads are not under `/mnt/volumes`.** They live on their own LVM volume rather
than in a named Docker volume (see the storage topology in `context/stacks.md`), so they get a
separate read-only bind — and note there is no `_data` segment on this one:

```bash
ls /mnt/downloads/qbittorrent/                            # what qBittorrent sees as /downloads
ls /mnt/downloads/qbittorrent/<torrent-name>/.unwanted/   # files marked "do not download"
```

> **This is no longer an explicit allowlist.** Any volume that exists — including ones added
> after this container was built — is readable. The previous per-volume list already included
> ACME private keys and the Authelia session store, so this is not a new *class* of exposure,
> but it is no longer audited volume-by-volume. Assume `claude-dev` can read every secret that
> lives in a Docker volume.

Requires root inside the container: `/var/lib/docker/volumes` is mode 0700 and volume contents
carry their own ownership. This is the same reasoning documented on `volume-sharer`.

### Plex logs — separate mount

Plex is the one service whose `/config` is **not** a named volume: `media/compose.yaml` binds
it from `/data1/plex_config/plex_config/_data`, which lives outside `/var/lib/docker/volumes`
and is therefore invisible under `/mnt/volumes`. Its `Logs` directory is mounted separately:

```bash
tail -200 "/mnt/plex-logs/Plex Media Server.log"     # the log that actually explains stream errors
ls /mnt/plex-logs/                                    # rotated logs, plugin logs, crash reports
```

Only `Logs` is mounted, not the whole config tree — the rest holds `Preferences.xml` (the
server token) and the library databases. Note that Plex logs still contain `X-Plex-Token=`
query strings in request lines; do not paste raw log lines into a chat transcript.

## nova.sh run logs

`nova.sh` tees every run to `${NOVA_CONFIG_PATH}/logs/nova-YYYY-MM-DD.log` on the host, and
`claude-dev` binds that directory read-only at `/mnt/nova-logs`:

```bash
tail -200 /mnt/nova-logs/current.log     # current.log -> today's dated file
tail -F   /mnt/nova-logs/current.log     # follow a run kicked off from the host
grep -l 'exit rc=[^0]' /mnt/nova-logs/nova-*.log   # find failed runs
ls /mnt/nova-logs/                       # 14 days of history, older files pruned
```

Each run is bracketed by markers, so runs are separable when grepping:

```
===== 2026-09-04 03:00:11 nova.sh heal all (pid 41233, user root) =====
...
===== exit rc=0 (2026-09-04 03:00:29) =====
```

This covers **interactive runs and the systemd timers alike** — `nova-heal` (every 3h) and
`nova-reconcile` (every 15min) both go through `nova.sh`, so their output lands here as well
as in the journal (which the containers cannot read).

Two commands are deliberately **not** logged: `logs` (would follow forever) and `config`
(prints fully-resolved compose output, i.e. every secret in `.env`).

Caveats:
- The log reflects the host's **live** `nova-config` — the tree at `${NOVA_CONFIG_PATH}`, which
  is *not* `~/nova-config` and *not* the `/repos/nova-config` checkout the containers edit.
  Read the real path off the running container rather than assuming:
  `docker inspect claude-dev --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' | grep nova-logs`.
  A change committed in `/repos` does not affect production until it is pulled on the host.
- If `${NOVA_CONFIG_PATH}/logs` is missing when the `dev` stack starts, Docker creates it as
  `root:root 0755` and `nova.sh` silently stops logging. Fix on the host with
  `sudo chown $USER "${NOVA_CONFIG_PATH}/logs"`. `nova.sh init` creates it correctly.
- Adding the mount needs `nova.sh recreate` (or `up`), **not** `restart` — a container's
  volumes are fixed when it is created, so a restart can never pick up a new bind mount.
- `NOVA_LOG=0` disables logging for a run; `NOVA_LOG_DIR=<path>` relocates it.

## Proxy Source

`infra/compose.yaml` → `socket-proxy` service (image: `tecnativa/docker-socket-proxy`).
The proxy listens on `tcp://socket-proxy:2375` within the `socket_proxy` network, and also on
`127.0.0.1:2375` on the host loopback for host-networked services (Glances, volume-sharer).
