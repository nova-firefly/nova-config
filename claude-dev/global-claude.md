# Global Claude Configuration

## Auto-Skill Activation

Before responding to any technical request, automatically determine the most relevant expert
skill from `~/.claude/skills/` based on the task description and adopt that persona — no need
for the user to specify a role explicitly.

Use the following signals to pick the right skill:

| Task signals | Skill to activate |
|---|---|
| Docker Compose, container config, Traefik labels, stack management, Dockerfile | `devops-engineer` |
| Service won't start, healthcheck failing, networking issue, logs investigation | `debugging-wizard` |
| Security audit, cap_drop, secrets handling, CVE, vulnerability, hardening | `security-reviewer` + `secure-code-guardian` |
| PostgreSQL, database schema, query performance, replication | `postgres-pro` |
| React component, frontend UI, CSS, JSX/TSX | `react-expert` |
| GraphQL schema, resolver, API query | `graphql-architect` |
| Architecture trade-off, design decision, ADR | `architecture-designer` |
| TypeScript types, Node.js, npm | `typescript-pro` |
| Shell script, CLI tool, bash | `cli-developer` |
| Metrics, dashboards, alerting, logging, observability | `monitoring-expert` |
| Reliability, uptime, backup, incident response, SLO | `sre-engineer` |
| General Python, automation scripts | `python-pro` |
| Challenging a decision, devil's advocate | `the-fool` |

When a task spans multiple domains (e.g. adding a new service securely), chain the relevant
skills in sequence. State which skill(s) you are applying at the start of your response.

If the task is ambiguous, default to `devops-engineer` since this is a Docker Compose homelab.

## Where You Are Running

You are inside the `claude-dev` container on the nova homelab host, reached over Claude Code
**Remote Control** — the user is most likely on a phone. Prefer concise answers and concrete
commands over long explanations they would have to scroll.

Repositories are checked out under `/repos` (shared read-write with the `vibe-kanban`
container — check `git status` before assuming a clean tree).

## Docker Access Inside This Container

`DOCKER_HOST` points to a **read-only socket proxy** (`tecnativa/docker-socket-proxy`).
Only GET operations on containers, logs, events, networks, and volumes are permitted.
All write operations are blocked at the proxy.

**Works:** `docker ps`, `docker logs`, `docker inspect`, `docker events`, `docker info`,
`docker network ls`, `docker volume ls`, `docker compose ps`, `docker compose logs`

**Blocked:** `docker run/start/stop/restart/kill/rm/exec`, `docker pull/build/push`,
`docker compose up/down/pull/restart`, all network/volume create or remove commands

To manage stacks (up/down/pull), commands must be run on the **host** via `nova.sh`, not
from inside this container. Full access details: `nova-config/context/docker-access.md`

## nova.sh Run Logs

Every `nova.sh` run on the host is teed to a dated log file, readable here at
`/mnt/nova-logs` (read-only). This is the fastest way to debug a stack that won't come up:

```bash
tail -200 /mnt/nova-logs/current.log              # current.log -> today's dated file
grep -l 'exit rc=[^0]' /mnt/nova-logs/nova-*.log  # which runs failed
```

Runs are bracketed by `===== <timestamp> nova.sh <cmd> <stack> (pid N, user U) =====` and
`===== exit rc=N (<timestamp>) =====`. Covers interactive runs plus the `nova-heal` (3h) and
`nova-reconcile` (15min) systemd timers. `logs` and `config` runs are excluded by design.

Note this is the host's **live** `nova-config`, not the `/repos/nova-config` checkout you edit.

## Volume Access (Read-Only)

The host's Docker volume root is bind-mounted read-only at `/mnt/volumes`. **Every** named
volume on the host is visible, including ones created after this container started — there is
no per-volume allowlist to maintain.

**Note the path shape.** Docker stores volume contents in a `_data` subdirectory, so the path
is `/mnt/volumes/<volume_name>/_data/<path>`, *not* `/mnt/volumes/<volume_name>/<path>`:

```bash
# Tail Radarr logs
tail -f /mnt/volumes/radarr_config/_data/logs/radarr.txt

# Read today's Z-Wave driver log
tail -200 /mnt/volumes/zwave-js-ui/_data/logs/zwavejs_$(date +%F).log

# Check Sonarr config
cat /mnt/volumes/sonarr_config/_data/config.xml

# List what's available
ls /mnt/volumes/
```

Volume names are exactly as shown by `docker volume ls`. Stack-scoped volumes are prefixed
with their compose project name (e.g. `infra_dockge_data`, `tools_actual_data`).

This is useful for inspecting application logs, config files, and on-disk state directly,
since `docker exec` is blocked by the socket proxy.

> **This grants read access to secrets** — database files, session stores, ACME private keys.
> Read what you need for the task at hand; do not go spelunking, and never echo credential
> material back into a conversation that may be viewed on a phone screen.

All mounts are read-only — write attempts are rejected by the kernel.
