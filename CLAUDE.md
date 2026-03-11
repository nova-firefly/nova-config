# Nova Config - Claude Context

Nova is a self-hosted Docker Compose infrastructure for a personal homelab. All services are organized into independent stacks managed via `nova.sh`.

## Project Layout

```
nova-config/
├── nova.sh                        # Master CLI: up/down/pull/update/logs/ps/config
├── .env / .env.example            # All secrets and shared settings
├── docker-compose.<stack>.yaml    # One file per stack (9 stacks total)
├── traefik/dynamic.yaml           # Routes for host-mode services (not Docker-discoverable)
├── homepage/                      # Dashboard config (settings/services/widgets YAML)
├── vibe-kanban/Dockerfile         # Dev container with Claude Code, gh CLI, Docker CLI
└── movienight/                    # Git submodule — separate repo for movie app
```

See `context/stacks.md` for full stack/service inventory and ports.
See `context/patterns.md` for conventions to follow when editing compose files.
See `context/claude-skills.md` for which Claude expert skill to use for each task type.

## Key Conventions

- **One compose file per stack** — never merge stacks into a single file
- **All services use `restart: unless-stopped`**
- **Traefik routing via labels** on each service; `traefik.enable: "true"` required
- **Homepage labels** expose services to the dashboard (see patterns.md for label format)
- **WUD labels** control auto-update watching per service (see patterns.md)
- **`cap_drop`** list applied to most media/arr services for security hardening
- **External volumes** declared at bottom of each compose file; pre-created before first `up`
- **`traefik_default` network** must exist before any stack comes up — `nova.sh up` creates it automatically
- **Environment variables** always sourced from `.env`; never hardcode secrets

## Common Tasks

### Add a new service to an existing stack
1. Add service block to `docker-compose.<stack>.yaml` following patterns in `context/patterns.md`
2. Add Traefik, Homepage, and WUD labels
3. Declare any new external volumes at bottom of the file
4. Add env vars to `.env.example` with stack annotation
5. Update `context/stacks.md` with the new service

### Add a new stack
1. Create `docker-compose.<stackname>.yaml`
2. Add stack name to `ALL_STACKS` in `nova.sh` (line 27)
3. Add WUD trigger env vars to the `wud` service in `docker-compose.infra.yaml`
4. Update `context/stacks.md`

### Add a host-mode service to Traefik
Edit `traefik/dynamic.yaml` — add router + service pointing to `http://host.docker.internal:<port>`

### Add a service to Homepage dashboard
Add `homepage.*` labels to the service (see patterns.md). Homepage reads Docker labels automatically.

## Environment Variables

Shared across stacks: `TZ`, `PUID`, `PGID`, `NOVA_HOSTNAME`, `NOVA_DOMAIN`

Stack-specific vars documented in `.env.example` and `context/stacks.md`.

## Claude Skills

Claude expert skills (from Jeffallan/claude-skills) are installed in the vibe-kanban container
at `~/.claude/skills/`. They are pre-baked into the Docker image and copied to the volume on
first container start via `vibe-kanban/entrypoint.sh`.

See `context/claude-skills.md` for a task → skill mapping guide.

Quick reference for common tasks:
- Docker/compose work → `devops-engineer`
- Debugging → `debugging-wizard`
- Security review → `security-reviewer` + `secure-code-guardian`
- PostgreSQL → `postgres-pro`
- Movienight frontend → `react-expert`
- Movienight backend → `graphql-architect`
- Architecture decisions → `architecture-designer`

## Keeping Context Up To Date

When making changes, update the relevant context file:
- New/removed service → update `context/stacks.md`
- New convention or pattern → update `context/patterns.md`
- New skill guidance → update `context/claude-skills.md`
- Structural change → update this file (`CLAUDE.md`)
