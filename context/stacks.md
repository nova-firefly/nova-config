# Stack & Service Inventory

All stacks managed via `./nova.sh` (or via the Dockge UI at `dockge.${NOVA_DOMAIN}`). Stack order in `ALL_STACKS` (nova.sh) controls startup order. Each stack lives in its own directory containing `compose.yaml` and a `.env` symlink to the shared root `.env`.

## Stack Summary

| Stack | File | Services |
|-------|------|----------|
| infra | infra/compose.yaml | traefik, homepage, arcane, dockge, duckdns, glances, volume-sharer, wud, scrutiny, socket-proxy, socket-proxy-sablier, sablier, runners-socket-proxy, nova-config-sync, runner-nova-config, runner-movienight, runner-todoassist |
| authelia | authelia/compose.yaml | authelia, redis |
| media | media/compose.yaml | plex, radarr, sonarr, bazarr, prowlarr, tautulli, seerr, kometa, kometa-quickstart, internal-webhook, gluetun, qbittorrent, decluttarr, recyclarr, homescreen-hero |
| immich | immich/compose.yaml | immich-server, immich-machine-learning, immich-postgres, immich-redis, immich-power-tools |
| home | home/compose.yaml | homeassistant, zwave-js-ui, music-assistant, matter-server |
| movienight | movienight/compose.yaml | movienight-frontend, movienight-backend, movienight-db |
| dev | dev/compose.yaml | claude-dev |
| tools | tools/compose.yaml | actual, actual-mcp, stirling-pdf, vikunja, uptime-kuma, ntfy, snapotter, shell |
| backup | backup/compose.yaml | backrest |
| gaming | gaming/compose.yaml | minecraft |
| movienight-test | movienight-test/compose.yaml | movienight-test-frontend, movienight-test-backend, movienight-test-db (CI-only; excluded from reconcile). Frontend + backend are **on-demand via Sablier** (group `movienight-test`, 60m idle); DB stays running. |
| strava-hevy | strava-hevy/compose.yaml | strava-hevy |
| todoassist | todoassist/compose.yaml | todoassist |
| hermes | hermes/compose.yaml | hermes |

---

## infra stack (`infra/compose.yaml`)

**Purpose:** Core infrastructure — reverse proxy, DNS, dashboard, monitoring, updates

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| traefik | traefik:v3.6 | 80, 443 | traefik.NOVA_DOMAIN | Wildcard TLS via DuckDNS DNS-01 challenge |
| homepage | ghcr.io/gethomepage/homepage | 3000 | home.NOVA_DOMAIN | Dashboard; reads Docker labels + `../homepage/` config (root-level dir) |
| arcane | ghcr.io/getarcaneapp/arcane | 3552 | arcane.NOVA_DOMAIN | Container management UI (per-container) |
| dockge | louislam/dockge:1 | 5001 | dockge.NOVA_DOMAIN | Compose stack manager (per-stack); mobile-friendly; reads/writes `<stack>/compose.yaml` on disk via **identity-mapped** `${NOVA_CONFIG_PATH}:${NOVA_CONFIG_PATH}` mount (host path = in-container path) so `../foo` bind-mounts in stack files resolve identically inside Dockge and on the host |
| duckdns | lscr.io/linuxserver/duckdns | — | — | Dynamic DNS updater |
| glances | nicolargo/glances:latest-full | 61208 (host) | glances.NOVA_DOMAIN | System monitor; host network mode → routed via traefik/dynamic.yaml |
| volume-sharer | gdiepen/volume-sharer | 139, 445 (host) | — | Samba share of Docker volumes |
| wud | getwud/wud | 3003→3000 | wud.NOVA_DOMAIN | Watch Update Docker; notify-only (Discord). Manual deploys via Dockge / Arcane / `nova.sh update` |
| scrutiny | ghcr.io/analogj/scrutiny:master-omnibus | 8082→8080 | scrutiny.NOVA_DOMAIN | S.M.A.R.T. hard drive health monitoring; needs SYS_RAWIO + device passthrough |
| socket-proxy-sablier | tecnativa/docker-socket-proxy | — | — | Scoped write-allowlist socket proxy for Sablier only. `CONTAINERS=1,POST=1,INFO=1,VERSION=1,EVENTS=1`; no IMAGES/NETWORKS/VOLUMES/EXEC/BUILD/SYSTEM/SECRETS. Reachable only on `sablier_internal` (internal-only bridge, no egress). |
| sablier | sablierapp/sablier:1.15.0 | 10000 (internal only) | — | On-demand container controller: stops idle containers, wakes them on the next HTTP request via a Traefik plugin. Target services opt in with `sablier.enable=true` + `sablier.group=<service>` labels plus a matching per-service `sablier-<service>@file` middleware (one per on-demand service for independent lifecycles). See `context/patterns.md` for the pattern. Plugin version pinned in traefik's static args (`v1.3.0`) and daemon image tag must stay compatible. |
| runners-socket-proxy | tecnativa/docker-socket-proxy | — | — | Write-allowlist socket proxy for self-hosted runners (POST=1, EXEC=0, BUILD=0, SECRETS=0, SYSTEM=0); reachable only on `runners_net` |
| nova-config-sync | alpine/git (pinned digest) | — | — | Sole writer to `/srv/nova-config`; loops `git fetch && reset --hard origin/main` every 10 min. Replaces the deleted `.github/workflows/sync.yml` Actions round-trip |
| runner-nova-config | myoung34/github-runner (pinned digest) | — | — | Ephemeral self-hosted runner for `nova-firefly/nova-config`; labels `nova,nova-config`; jobs launch via `runners-socket-proxy` |
| runner-movienight | myoung34/github-runner (pinned digest) | — | — | Ephemeral runner for `nova-firefly/movienight`; serves both prod and test via labels `nova,movienight,movienight-test` (one runner per repo, not per environment) |

**External volumes:** `traefik_acme`, `samba_config`, `arcane_data`, `scrutiny_data`, `dockge_data`

**Config files (bind-mounted):** `../scrutiny/scrutiny.yaml` (root-level `scrutiny/` dir; path is `..` from the infra stack dir)

**External networks:** `traefik_default` (shared)

**Compose-managed networks:** `runners_net` (bridge, not internal — carries runner ↔ proxy traffic and gives runners outbound internet for GitHub long-poll), `sablier_internal` (bridge, `internal: true` — sablier ↔ socket-proxy-sablier only, no egress)

**Compose-managed volumes:** `runner_nova_config_state`, `runner_movienight_state`, `runner_todoassist_state` — per-runner registration state so ephemeral runners don't re-register on every restart

**Required env:** `GH_PAT` for the three runner containers (fine-grained PAT scoped to all three runner repos with `Administration: write`). See `context/runners.md` for setup, digest pinning, rotation, and troubleshooting.

**WUD mode:** notify-only (Discord). Manual deploys via Arcane UI or `nova.sh update`. Runner images are explicitly `wud.watch: "false"` — they are digest-pinned and updated only via deliberate PRs.

---

## authelia stack (`authelia/compose.yaml`)

**Purpose:** Central authentication portal; provides forward-auth middleware for all protected services via Traefik

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| authelia | authelia/authelia:4 | 9091 | auth.NOVA_DOMAIN | Authentication portal + forwardAuth API |
| redis | redis:7-alpine | — | — | Session storage; internal network only |

**External volumes:** `authelia_data` (SQLite DB at `/config/data/db.sqlite3`), `authelia_redis` (Redis persistence)

**Config files (bind-mounted):** sit alongside `compose.yaml` inside the `authelia/` dir
- `./configuration.yml` (i.e. `authelia/configuration.yml`) — Main config (read-only); uses Go template syntax via `X_AUTHELIA_CONFIG_FILTERS=template`
- `./users_database.yml` (i.e. `authelia/users_database.yml`) — User accounts (writable — Authelia updates on password change)

**Middleware reference:** `authelia@file` — defined in `traefik/dynamic.yaml`; add to any router with: `traefik.http.routers.<name>.middlewares: "authelia@file"`

**Path bypasses (`access_control.rules` in `configuration.yml`):** `bazarr` `^/api` — key-authenticated API reachable by scripts; UI stays behind 2FA. Add other `*arr` APIs the same way if needed.

**Services excluded from Authelia protection:**
- `plex` — native Plex app uses token auth; redirect breaks all clients
- `homeassistant` — webhooks, integrations, mobile app use Bearer tokens; routed via dynamic.yaml (host network mode)
- `immich` — mobile app uses API key headers; redirect breaks sync
- `overseerr` — "Sign in with Plex" OAuth flow + mobile app
- `ma` (Music Assistant) — deep HA integration (add `middlewares: [authelia]` in dynamic.yaml to enable)
- `root-redirect` — redirect rule, not a service; wrapping causes redirect loop

**Required env:** `AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`

**Networks:** `authelia_internal` (authelia ↔ redis only), `traefik_default` (traefik ↔ authelia)

**Setup:**
```bash
# Generate secrets
openssl rand -hex 64  # run 3x for JWT_SECRET, SESSION_SECRET, STORAGE_ENCRYPTION_KEY

# Generate password hash (replace placeholder in authelia/users_database.yml — alongside compose.yaml)
docker run --rm authelia/authelia:4 authelia crypto hash generate argon2 --password 'YourPassword'

# Create volumes
docker volume create authelia_data && docker volume create authelia_redis

# Start
./nova.sh up authelia
```

**Disabling native auth in *arr apps (recommended once Authelia is running):**
- Radarr/Sonarr/Prowlarr/Bazarr: Settings → General → Authentication → **External**
- Tautulli: Settings → Web Interface → **Disable login**

---

## media stack (`media/compose.yaml`)

**Purpose:** Media server and content acquisition pipeline

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| plex | ghcr.io/linuxserver/plex | 32400 | plex.NOVA_DOMAIN | Media server; NVIDIA GPU passthrough |
| radarr | ghcr.io/linuxserver/radarr | 7878 | radarr.NOVA_DOMAIN | Movie management; on `media` network |
| sonarr | ghcr.io/linuxserver/sonarr | 8989 | sonarr.NOVA_DOMAIN | TV show management; on `media` network |
| bazarr | lscr.io/linuxserver/bazarr | 6767 | bazarr.NOVA_DOMAIN | Subtitle management |
| prowlarr | lscr.io/linuxserver/prowlarr | 9696 | prowlarr.NOVA_DOMAIN | Indexer aggregator; on `media` network |
| tautulli | ghcr.io/tautulli/tautulli | 8181 | tautulli.NOVA_DOMAIN | Plex stats/monitoring |
| seerr | ghcr.io/seerr-team/seerr | 5055 | seerr.NOVA_DOMAIN | Media request management |
| homescreen-hero | trentferguson/homescreen-hero | 8000 | homescreen-hero.NOVA_DOMAIN | Plex dashboard: collection rotation, Tautulli/Seerr widgets, watch history tools. **On-demand via Sablier** (group `tools`, 60m idle); no Authelia because the app has its own JWT login — probe-wake risk mitigated by `ignoreUserAgent`. Revert if kiosk/bot traffic keeps it warm. |
| kometa | kometateam/kometa | — | — | Plex collection manager; runs daily at 05:00 via trigger-wrapper.sh; config in `../kometa/` (root-level dir, mounted from media stack); no web UI |
| kometa-quickstart | kometateam/quickstart:develop | 7171 | kometa-quickstart.NOVA_DOMAIN | Web UI config wizard for Kometa; shares `../kometa/` bind-mount to write config.yml |
| internal-webhook | local build (`../internal-webhook/`) | 9000 (internal only) | — | Internal webhook server for container-to-container triggers; only reachable from `internal_webhook` internal Docker network; currently handles `/kometa/trigger` |
| gluetun | qmcgaw/gluetun | 8090 | qbittorrent.NOVA_DOMAIN | Mullvad WireGuard VPN gateway; Traefik routes qBittorrent through it |
| qbittorrent | lscr.io/linuxserver/qbittorrent | (via gluetun) 8090 | qbittorrent.NOVA_DOMAIN | Torrent client; `network_mode: service:gluetun`; WebUI on 8090 (WEBUI_PORT=8090) |
| decluttarr | ghcr.io/manimatter/decluttarr | — | — | Auto-cleans stalled / failed / slow downloads from *arr queues; config in `../decluttarr/config.yaml` (root-level dir); no UI |
| recyclarr | ghcr.io/recyclarr/recyclarr | — | — | Syncs TRaSH Guides quality profiles + custom formats to Sonarr & Radarr; config in `../recyclarr/recyclarr.yml`; cron via `CRON_SCHEDULE` (default 04:00 daily); no UI |

**Key:** qbittorrent runs inside gluetun's network namespace (`network_mode: service:gluetun`). Traefik labels are on gluetun, not the sidecar.

### Storage topology

Four physical disks, four separate filesystems:

| Host mount | Device | Medium | Size | Holds |
|---|---|---|---|---|
| `/` | `ubuntu--vg-ubuntu--lv` on sda3 | SSD 480G | 200 GiB | all Docker named volumes (arr SQLite, Immich, Postgres) |
| `/srv/downloads` | `ubuntu--vg-downloads--lv` on sda3 | SSD 480G | ~245 GiB | qBittorrent `/downloads` |
| `/data1` | sdc | HDD | 1.8T | `/plex_tv_1`, `/plex_movies_1`, plex config |
| `/data2` | sdb | HDD | 931G | `/plex_tv_2`, `/plex_movies_2` |
| `/data3` | sdd | HDD | 9.1T | `/plex_tv_3`, `/plex_movies_3` |

**Media paths:** `/data1`, `/data2`, `/data3` — mounted directly (not volumes) for media libraries

**Download paths in arr services:** torrents at `/downloads`, bind-mounted from
`/srv/downloads/qbittorrent` on a dedicated LVM volume. It is deliberately *not* a Docker
named volume: on 2026-09-04 a 30-episode season grab preallocated ~88 GB into the old
`qbittorrent_data` volume, filled the root LV to 0 bytes, and Sonarr's SQLite started
returning `disk I/O error`. Splitting downloads onto their own filesystem means a runaway
download can only break downloads.

**No hardlinks, ever.** `/downloads` and all six library roots are on four different
filesystems, so Sonarr/Radarr imports are always copy+delete, never atomic moves or
hardlinks. Because the library itself is spread across three disks, no single download
location could hardlink into all root folders — this is a deliberate trade-off, not an
oversight. Budget for the transient second copy during import.

**Disk guard:** `host-scripts/disk-space-guard.sh` (systemd timer, every 15 min) watches all
five mounts, warns via ntfy at 85% and pauses qBittorrent at 92%. Install with
`sudo ./host-scripts/install-disk-space-guard.sh`.

**External volumes:** `bazarr_config`, `gluetun_data`, `homescreen_hero_data`, `overseerr_config` (aliased as `seerr_config`), `prowlarr_config`, `qbittorrent_config`, `radarr_config`, `sonarr_config`, `tautulli_config`

**Required env:** `PUID`, `PGID`, `TZ`, `PLEX_CLAIM_TOKEN`, `PLEX_TOKEN`, `MULLVAD_WIREGUARD_PRIVATE_KEY`, `MULLVAD_WIREGUARD_ADDRESSES`, `QBITTORRENT_USER`, `QBITTORRENT_PASS`, `RADARR_API_KEY`, `SONARR_API_KEY`, `RADARR_ROOT_FOLDER`, `RADARR_QUALITY_PROFILE`, `TAUTULLI_API_KEY`, `SEERR_API_KEY`, `HSH_AUTH_PASSWORD`, `HSH_AUTH_SECRET_KEY`

---

## immich stack (`immich/compose.yaml`)

**Purpose:** Photo/video management with ML-based organization

| Service | Image | Notes |
|---------|-------|-------|
| immich-server | ghcr.io/immich-app/immich-server | Main app |
| immich-machine-learning | ghcr.io/immich-app/immich-machine-learning | ML inference |
| immich-postgres | tensorchord/pgvecto-rs | PostgreSQL with vector extension |
| immich-redis | redis | Cache |
| immich-power-tools | ghcr.io/immich-power-tools/immich-power-tools | Library organizer UI — face merge, album suggestions, analytics; at `immich-power-tools.NOVA_DOMAIN`. **On-demand via Sablier** (group `tools`, 60m idle). Now gated by Authelia (previously exposed) — Sablier needs an auth layer in front so probes don't wake it. |

**External volumes:** `immich_power_tools_data`

**Required env:** `IMMICH_DB_PASSWORD`, `UPLOAD_LOCATION`, `DB_DATA_LOCATION`, `DB_USERNAME`, `DB_DATABASE_NAME`, `IMMICH_POWER_TOOLS_API_KEY`

---

## home stack (`home/compose.yaml`)

**Purpose:** Home automation and smart devices

| Service | Notes |
|---------|-------|
| homeassistant | Core home automation platform; host network mode → routed via traefik/dynamic.yaml at `ha.NOVA_DOMAIN:8123` |
| zwave-js-ui | Z-Wave device management |
| music-assistant | Music streaming; host network mode → routed via traefik/dynamic.yaml at `ma.NOVA_DOMAIN:8095` |
| matter-server | Matter protocol server; host network mode; WebSocket on port 5580; HA connects via `ws://[host_ip]:5580/ws` |

**External volumes:** `matter_server_data`

**Required env:** `ZWAVE_SESSION_SECRET`

---

## movienight stack (`movienight/compose.yaml`)

**Purpose:** Movie suggestion web app (custom-built)

| Service | Image/Build | Notes |
|---------|-------------|-------|
| movienight-frontend | ghcr.io/nova-firefly/movienight:latest | React frontend; routes all non-/graphql traffic |
| movienight-backend | ghcr.io/nova-firefly/movienight-backend:latest | GraphQL API on port 4000; built by CI in movienight repo |
| movienight-db | postgres:15-alpine | Internal network only |

**Networks:** `movienight_internal` (internal: true) isolates DB from Traefik; `internal_webhook` (external, internal: true) connects backend to `internal-webhook` in media stack

**Routing:** Traefik routes `/graphql` to backend, everything else to frontend — both on `movienight.NOVA_DOMAIN`

**Image:** Both images are built by CI in [`nova-firefly/movienight`](https://github.com/nova-firefly/movienight) on push to `master` and published to GHCR. Deploy runs on `runner-movienight` (self-hosted, see `context/patterns.md § CI Deploy via Self-Hosted Runner`) and does `docker compose pull && up -d` against `movienight/compose.yaml`, gated on all three services reporting `running`. `deploy-test.yml` uses the same runner via the shared `movienight-test` label to deploy PR branches to `movienight-test`. WUD watches the digest of `:latest` and notifies on Discord (redundant with the runner deploy but kept as a drift alarm); redeploy manually with `./nova.sh update movienight`.

**Required env:** `MOVIENIGHT_DB_PASSWORD`

---

## dev stack (`dev/compose.yaml`)

**Purpose:** Development environment

| Service | Image/Build | Notes |
|---------|-------------|-------|
| claude-dev | local build (`../claude-dev`) | One `claude remote-control` server per git repo under `/repos`; gh CLI, Docker CLI. **No ports, no Traefik** — outbound-only |

**claude-dev** replaced vibe-kanban (removed 2026-09-10, along with vibe-kanban-tools and
its CI runner). `/repos` still lives on the `vibe-kanban-repos` volume — the name is
historical, and the out-of-repo `kandev` project mounts it too, so it must not be removed.

Reach it from the Claude mobile app or claude.ai/code. There is no web UI on the host and no
listener: `claude remote-control` speaks outbound HTTPS to api.anthropic.com only.

**One server per repo.** At startup the entrypoint scans `/repos/*/` and starts a supervised
`claude remote-control` server in each git checkout, so the session list shows one online entry
per repo (`nova-config`, `movienight`, ...) rather than a single generic one. Clone a repo into
`/repos` and restart the container to get a server for it — no config change. Set
`CLAUDE_DEV_REPOS` (space-separated names) to narrow the set. With no git repos found it falls
back to a single `--spawn same-dir` server at `/repos`.

The per-repo split is not cosmetic. A server's working directory decides where its sessions
live, and `--spawn worktree` **requires that directory to be a git repository** — `/repos` is
just a folder of checkouts, so a single server rooted there could only run `--spawn same-dir`,
where concurrent sessions edit one working tree and conflict.

**Sessions are on demand.** Each server pre-creates one session that stays in the repo root
(`--create-session-in-dir`, on by default), and every *additional* session spawned from the app
gets its own git worktree at `<repo>/.claude/worktrees/<name>/` on a `worktree-<name>` branch.
Those branch from the **remote's default branch**, not your local work — set
`worktree.baseRef: "head"` in settings to change that. `.claude/` is gitignored in nova-config;
check the other repos or spawned worktrees will show up as untracked files.

**Restarts re-adopt worktree sessions.** Root sessions survive a restart on their own — their ID
is derived from the directory, so each server re-creates the identical one and it looks like a
resume. Sessions spawned into worktrees do not: nothing serves them and they drop off
claude.ai, even though worktree, branch and transcript are all still on disk. After starting the
per-repo servers the entrypoint therefore scans `<repo>/.claude/worktrees/bridge-cse_*` and
re-attaches each one with `--session-id` — the spawner encodes the claude.ai session ID in that
directory name, so no extra state is needed. `--continue` cannot do this: its "last session"
record is keyed to the directory the *server* ran in, so from inside a worktree it resolves to
the root session and is refused as already served. Adoption is one-shot (`--session-id` exits
when the session ends) and only applies within the CLI's ~4h window, so a container down longer
than that leaves those sessions to be reopened from the app.

**A root session that dies is rebuilt.** `--create-session-in-dir` runs once, when the server
starts. End that session from the app or let it crash and nothing recreates it: the server stays
up, keeps serving worktree sessions, and the repo is left with nothing to type into — the symptom
is a repo showing one fewer session than its siblings for no visible reason. `supervise()` is
blind to it because it only watches for the *server* exiting. `claude-dev/root-session-watchdog.sh`
polls each repo's `bridge-pointer.json` for its root session id, checks whether a runner process
still carries that id, and after two consecutive misses restarts that repo's server so step 8
recreates the session. Re-adopting the dead session by `--session-id` would be wrong here — it
resurrects the ended conversation, where the point of the root session is that it is empty.
Restarting a server drops every session it holds, so the watchdog waits until the server is
serving none: a root session lost while you are working in a worktree is repaired once that work
ends, never at its expense. A `CLAUDE_DEV_WATCHDOG_COOLDOWN` (default 600s) floor between
restarts keeps a root session that dies on every boot from becoming a restart loop. Disable with
`CLAUDE_DEV_ROOT_SESSION_WATCHDOG=false`.

**Stale worktree locks are cleared at boot.** Capacity is 32 per server — nova passes no
`--capacity`, and 32 is the CLI default for `--spawn worktree`. A repo showing **"1 of 1 sessions"**
in the app instead of "N of 32" is not a capacity setting: it means
`projects.<repo>.activeWorktreeSession` is set in `claude.json`. A session that enters a worktree
writes that record and clears it on exit; if the container stops first the record is orphaned, and
because it lives in the `claude-dev-claude` volume rather than in the process, it survives every
restart and permanently pins that repo's server to the recorded worktree — no new sessions can be
spawned, and nothing in the logs says why. Step 5 of the entrypoint therefore strips
`activeWorktreeSession` from every project on the same pass that seeds workspace trust; nothing is
live that early in boot, so any record found is stale by definition. Cleared locks are logged as
`[entrypoint] Cleared stale worktree lock: <repo> (<worktree>)`. Note the status line in
`docker logs claude-dev` reads `Capacity: <in-use>/<max>`, so an idle healthy server sits at `1/32`
— the pre-created root session — not `0/32`.

**Auth is a one-time interactive OAuth login.** API keys and `claude setup-token` tokens are
not supported by remote-control. On first boot `docker logs claude-dev` prints the login
command; it is asked once, then never again while the `claude-dev-claude` volume survives.
To log in again later:

```bash
docker exec -it claude-dev claude    # then /login
```

`shell.${NOVA_DOMAIN}` gets you a host shell from a phone if you are not at the machine.

**Supervision:** in server mode Claude Code exits after ~10 min of network outage, so each
server runs under its own relaunch loop and SIGTERM is forwarded down to every one of them on
`docker stop`. `--continue` is deliberately absent: the docs state it "can't be combined with
`--session-id`, `--spawn`, `--capacity`, or `--create-session-in-dir`", and this uses `--spawn`.

The healthcheck (`claude-dev/healthcheck.sh`) compares live server count against the number the
entrypoint recorded at startup in `/run/claude-dev-expected`, so one repo's server dying
permanently marks the container unhealthy — a bare "is anything alive" check would not.

**Volume access:** one read-only bind of
`/var/lib/docker/volumes`, so paths carry a `_data` segment
(`/mnt/volumes/radarr_config/_data/logs/...`). See `context/docker-access.md`.

**Rebuild:** `./nova.sh recreate dev claude-dev` — `up` and `update` do not rebuild `build:`
services.

**Required env:** `GH_TOKEN` (claude-dev's `CLAUDE_DEV_*` vars are all optional and default sensibly)

---

## tools stack (`tools/compose.yaml`)

| Service | Image | Port | URL | Notes |
|---------|-------|------|-----|-------|
| actual | actualbudget/actual-server | 5006 | actual.NOVA_DOMAIN | Personal budgeting. **Always-on** (Sablier removed) — the `actual-mcp` connector reaches it directly at `http://actual:5006`, which bypasses Sablier, so it must stay up. Behind Authelia on the browser route. |
| actual-mcp | sstefanov/actual-mcp:v1.12.0 | 3000 (no host port) | actual-mcp.NOVA_DOMAIN | Actual Budget MCP (SSE) — remote Claude connector. **Public, no Authelia** (Claude calls from Anthropic's cloud); bearer-token auth (`--enable-bearer`) + `actual-mcp-sse@file` rate limit. Reaches `actual` over `traefik_default`; downloads a local budget copy to `/data`. Runbook + security posture: `context/actual-mcp.md`. |
| stirling-pdf | stirlingtools/stirling-pdf | 8080 | stirling-pdf.NOVA_DOMAIN | PDF manipulation tool. **On-demand via Sablier** (group `tools`, 60m idle); JVM cold start — `start_period` bumped to 60s so wake doesn't briefly flip to unhealthy. |
| vikunja | vikunja/vikunja | 3456 | vikunja.NOVA_DOMAIN | Task management. **On-demand via Sablier** (group `tools`, 60m idle). Assumes browser-only usage; if CalDAV subscribers or the mobile app poll the host, they'll keep it warm — revert this service and remove sablier labels. |
| uptime-kuma | louislam/uptime-kuma | 3002→3001 | status.NOVA_DOMAIN | Service uptime monitoring and alerting |
| ntfy | binwiederhier/ntfy | 80 | ntfy.NOVA_DOMAIN | Push notification server; no Authelia — must be reachable by webhooks. Also used by nova.sh to notify on up/down/update/recreate/restart (topic: `$NTFY_TOPIC`) |
| snapotter | ghcr.io/snapotter-hq/snapotter | 1349 | snapotter.NOVA_DOMAIN | Self-hosted image manipulation (50+ tools, local AI). Behind Authelia; internal auth also on with default `admin`/`admin` (change on first login). `/tmp/workspace` is a compose-managed volume — auto-cleaned by the app. **On-demand via Sablier** (group `tools`, 60m idle; see patterns.md). Cold-start ~60s. |
| shell | local build (`../shell/`) | 7681 | shell.NOVA_DOMAIN | Browser SSH terminal to host. ttyd (alpine) + openssh-client; reaches host sshd via `host.docker.internal:22` (docker bridge gateway). No SSH creds in the image — user types host secret in browser. |

**External volumes:** `stirling_config`, `uptime_kuma_data`, `vikunja_db`, `vikunja_files`, `ntfy_data`, `snapotter_data`

**Compose-managed volumes:** `actual_data` (named `tools_actual_data` by Docker Compose), `actual_mcp_data` (disposable local budget copy for `actual-mcp`; re-downloads on start), `snapotter_workspace` (ephemeral processing dir; safe to wipe)

**Shell auth model (defense in depth):**
1. Traefik TLS at the edge.
2. **Authelia 2FA** (default policy is `two_factor`, inherited automatically by `shell.NOVA_DOMAIN`).
3. **Host sshd** validates with whatever sshd is configured for (password, key, or key + PAM-TOTP).

Image is built locally from `../shell/Dockerfile` (just `tsl0922/ttyd:alpine` + `openssh-client`). Reason: the upstream `wettyoss/wetty` image hasn't been rebuilt since 2022; `tsl0922/ttyd` is rebuilt every few weeks.

Container hardening: `cap_drop: ALL`, `no-new-privileges`, `read_only: true` with `/tmp` tmpfs (ssh's `UserKnownHostsFile` is pointed at `/tmp/known_hosts`).

Recommended host hardening once `shell` is up (see `.env.example` Shell section for commands):
- Bind sshd to `127.0.0.1` + `172.17.0.1` only so it's unreachable from LAN / WAN.
- Add `pam_google_authenticator` to `$SHELL_SSH_USER` for a TOTP factor at the sshd layer.

**Required env (for shell):** `SHELL_SSH_USER` (stack refuses to start without it).

---

## backup stack (`backup/compose.yaml`)

| Service | Notes |
|---------|-------|
| backrest | Restic-based backup manager (Restic-based; supports S3, B2, SFTP, and more) |

**External volumes:** `backrest_backrest_cache`, `backrest_backrest_config`, `backrest_backrest_data`

---

## gaming stack (`gaming/compose.yaml`)

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| minecraft | itzg/minecraft-server:java25 | 25565 | — | Vanilla Minecraft; data in `minecraft_data` volume |

**External volumes:** `minecraft_data`

**Updates:** WUD watches the image digest and sends Discord notifications; redeploy with `./nova.sh update gaming`.

**First-run setup:**
```bash
docker volume create minecraft_data
./nova.sh up gaming
```

---

## strava-hevy stack (`strava-hevy/compose.yaml`)

**Purpose:** Always-on Strava → Hevy workout import service. Polls Strava on a schedule and pushes matching activities into Hevy. Companion to the desktop `underthebar` app — same import logic, different deployment.

| Service | Image/Build | Port | URL | Notes |
|---------|-------------|------|-----|-------|
| strava-hevy | ghcr.io/kjsb25/underthebar-server:latest | 8000 | strava-hevy.NOVA_DOMAIN | FastAPI; SQLite state at `/data/state.db`; protected by Authelia |

**Image:** Built by CI in [`kjsb25/underthebar`](https://github.com/kjsb25/underthebar) (`.github/workflows/build-server.yml`) on every push to `main` that touches `server/**`. Tags: `:latest` and `:sha-<short>`. WUD watches the digest and notifies on Discord; redeploy with `./nova.sh update strava-hevy`.

**External volumes:** `strava_hevy_data` (SQLite + persistent state — rotating Hevy refresh tokens, imported activity IDs, event log)

**Required env:** none — all secrets are entered through the web UI on first run and persisted in the volume. Optional: `STRAVA_HEVY_LOG_LEVEL`.

**Auth model:** Authelia (forwardAuth via `authelia@file`). The Strava OAuth callback is browser-initiated and carries the Authelia session cookie (domain set to `NOVA_DOMAIN`), so the callback passes through cleanly.

**Security hardening:** runs as non-root (uid 1000), read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, `/tmp` tmpfs. Only `/data` is writable.

**Bootstrap (one-time, after `nova.sh up strava-hevy`):**
1. Create a Strava API app at <https://www.strava.com/settings/api>; set **Authorization Callback Domain** to `strava-hevy.${NOVA_DOMAIN}`.
2. Visit `https://strava-hevy.${NOVA_DOMAIN}/`, authenticate via Authelia.
3. Settings → paste Strava Client ID/Secret.
4. Auth → Authorize Strava (completes OAuth, refresh token stored).
5. Auth → Hevy → paste `access_token` + `refresh_token` from your desktop's `~/.underthebar/session.json`.
6. Settings → enable polling, set interval (default 10 min).

**Recovery:** if Strava or Hevy refresh tokens are revoked, re-do the matching auth step. To wipe state, remove the `strava_hevy_data` volume; already-imported Hevy workouts are not duplicated because Hevy 409s and the service then PUTs to the same deterministic workout ID.

---

## todoassist stack (`todoassist/compose.yaml`)

**Purpose:** Todoist automation add-ons for a single user / single Todoist account. Runs a small set of modules on a schedule against the Todoist Sync API. v1 ships with one module — **Recurring task hygiene** — which detects recurring tasks that are overdue by more than a configurable grace threshold and either reschedules them to today or reports them to the activity log.

| Service | Image/Build | Port | URL | Notes |
|---------|-------------|------|-----|-------|
| todoassist | ghcr.io/nova-firefly/todoassist:latest | 8000 | todoassist.NOVA_DOMAIN | FastAPI; SQLite state at `/data/state.db`; protected by Authelia |

**Image:** Built by CI in [`nova-firefly/todoassist`](https://github.com/nova-firefly/todoassist) (`.github/workflows/build.yml`) on every push to `main`. Tags: `:latest` and `:sha-<short>`. WUD watches the digest and notifies on Discord; redeploy with `./nova.sh update todoassist`.

**External volumes:** `todoassist_data` (SQLite + persistent state — encrypted Todoist token, module config, activity log)

**Required env:** `TODOASSIST_ENCRYPTION_KEY` (Fernet key used to encrypt the Todoist API token at rest). Optional: `TODOASSIST_LOG_LEVEL`.

**Auth model:** Authelia (forwardAuth via `authelia@file`). No inbound webhooks in v1 — the Recurring task hygiene module runs on an internal scheduler only.

**Security hardening:** runs as non-root, read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, `/tmp` tmpfs. Only `/data` is writable.

**Bootstrap (one-time, after `nova.sh up todoassist`):**
1. Generate `TODOASSIST_ENCRYPTION_KEY` (see `.env.example`) and add to root `.env`.
2. Visit `https://todoassist.${NOVA_DOMAIN}/`, authenticate via Authelia.
3. Settings → paste Todoist API token (from Todoist → Settings → Integrations → Developer → API token) and **Test connection**.
4. Modules → **Recurring task hygiene** → set grace-days threshold, choose action (`reschedule` or `report`), enable **dry-run**, click **Run now**, review the activity log, then flip dry-run off and enable the schedule.

**Recovery:** if the Todoist token is revoked, re-do step 3. Losing `TODOASSIST_ENCRYPTION_KEY` means the stored token can no longer be decrypted — re-enter it via the UI. To wipe state, remove the `todoassist_data` volume.

## hermes stack (`hermes/compose.yaml`)

**Purpose:** Self-hosted [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) — always-on chat agent (Signal) with memory and cron, on a cheap model. Development work is **handed off to Claude Code** (your Claude subscription) through GitHub, never done by Hermes itself.

```
You ──Signal───▶ Hermes (MiniMax M3 via OpenRouter, US hosts, capped key)
                     │ files issue "@claude …" as kjsb25 (fine-grained PAT, Issues RW)
                     ▼
     GitHub ──▶ .github/workflows/claude.yml (claude-code-action, CLAUDE_CODE_OAUTH_TOKEN)
                     │ GitHub-hosted runner → branch / PR
                     ▼
     Hermes reports status back on request
```

| Service | Image/Build | Port | URL | Notes |
|---------|-------------|------|-----|-------|
| hermes | nousresearch/hermes-agent:stable | 9119 (container only) | hermes.NOVA_DOMAIN | `gateway run` + dashboard (`HERMES_DASHBOARD=1`), both supervised by s6-overlay inside the one container |
| hermes-signal-cli | ghcr.io/asamk/signal-cli:0.14.9 | 8080 (`hermes_signal` network only) | — | signal-cli HTTP daemon (JSON-RPC + SSE) for the bot's own Signal number. Non-root, `cap_drop: ALL`, read-only rootfs (`/tmp` tmpfs is `exec` — libsignal loads its JNI library from there). Pinned semver tag; WUD notifies on new releases |

**Image:** Upstream publishes `nousresearch/hermes-agent` on Docker Hub (`stable` = release-gated); it ships `docker-cli`, python3, git, curl (no `gh`, no `jq`). WUD watches the digest and notifies on Discord; redeploy with `./nova.sh update hermes`.

**Deviation from upstream's `docker-compose.yml`:** Upstream uses `network_mode: host`. Nova drops host mode so the container sits on `traefik_default` (Traefik label routing) and `socket_proxy`. Gateway and dashboard stay in **one** container — upstream only supports a split dashboard container when it shares the gateway's PID namespace.

**Dashboard auth (two layers):** Authelia 2FA at the Traefik edge, then Hermes' built-in username/password gate. Upstream made its gate mandatory on any non-loopback bind after the June 2026 exposed-dashboard campaign (`--insecure` / `HERMES_DASHBOARD_INSECURE` are now no-ops), so the dashboard **fails closed at startup** if `HERMES_DASHBOARD_USERNAME`/`_PASSWORD` are unset. `HERMES_DASHBOARD_PUBLIC_URL` must match the Traefik host or requests are rejected with "Invalid Host header".

**Model + data residency:** MiniMax M3 on OpenRouter, pinned in `hermes/managed/config.yaml` (read-only managed scope — the agent can't switch models or hosts) with `provider_routing.models` to US-hosted providers (DeepInfra, Together, Parasail), `require_parameters: true`, `data_collection: deny` (`only` means no other host is ever tried). MiniMax's own API (not US) is never used. ~$0.28/$1.10 per M tokens. The spend cap is the credit limit on the dedicated `HERMES_OPENROUTER_API_KEY` — no other provider key is wired into the container.

**GitHub + Claude handoff:** Hermes' **built-in `github` skill** does repo status / PRs / CI via its curl method: `gh-env.sh` reads `GITHUB_TOKEN` from `/opt/data/.env` (set once with `hermes config set GITHUB_TOKEN`). It can't come from a container env var — Hermes always strips `GH_TOKEN`/`GITHUB_TOKEN` from tool subprocesses and refuses to pass them through. `hermes/skills/claude-handoff/SKILL.md` (bind-mounted read-only into `/opt/data/skills/software-development/claude-handoff`; the skill loader ignores managed scope) reuses that auth to file an issue whose body starts with `@claude` and track Claude's comments / workflow runs. The bundled `claude-code` and `codex` skills are disabled once with `hermes config set skills.disabled` so Hermes never runs a coding CLI itself. Workflow side: `.github/workflows/claude.yml` — only fires for actor `kjsb25`, runs on **GitHub-hosted** runners (not the nova self-hosted runner), auth via `CLAUDE_CODE_OAUTH_TOKEN` (plan usage, shared with interactive Claude Code). To enable another repo, copy the workflow and its secret there.

**Docker access:** `DOCKER_HOST=tcp://socket-proxy:2375` on the `socket_proxy` network. Read-only verbs only (see `context/docker-access.md`).

**Repo read access:** The `/repos` checkouts (`vibe-kanban-repos` volume, shared with `claude-dev`) at `/repos:ro`. Service config volumes are deliberately **not** mounted — they hold API keys (arr `config.xml`, qbittorrent) and the agent is chat-reachable with internet egress. Use `docker logs` via the proxy instead.

**External volumes:** `hermes_data` (persistent agent state — sessions, memory, skills, `.env`, `config.yaml`, kanban SQLite), `hermes_signal_data` (bot's Signal identity keys + message store — back it up; losing it means re-registering the number) and `vibe-kanban-repos` (`:ro`).

**Required env:** `HERMES_DASHBOARD_USERNAME`, `HERMES_DASHBOARD_PASSWORD`, `HERMES_DASHBOARD_SECRET`, `HERMES_OPENROUTER_API_KEY`, `HERMES_GITHUB_TOKEN`, `HERMES_SIGNAL_ACCOUNT`, `HERMES_SIGNAL_ALLOWED_USERS` (plus shared `NOVA_DOMAIN`, `TZ`, `PUID`, `PGID`). Prefixed so they are dedicated, scoped credentials rather than shared host keys.

**Security:**
- Dashboard stores state on disk in `hermes_data` — never publish port 9119.
- Container hardening: `cap_drop: ALL` + only what s6-overlay's root-run init needs (`CHOWN DAC_OVERRIDE FOWNER SETUID SETGID KILL`), `no-new-privileges`, `pids_limit: 1024`, `mem_limit: 4g`. No read-only rootfs (init rewrites `/etc/passwd` via usermod).
- Signal answers only `HERMES_SIGNAL_ALLOWED_USERS` (groups ignored). The signal-cli daemon has **no auth** — it is reachable only on the stack-private `hermes_signal` network; never add Traefik labels or ports to it.
- The bot uses a **dedicated number**, not yours. Linking signal-cli to your own number ("Note to Self" mode) would give it a copy of every Signal conversation you have.
- `nova-config` is a **public** repo: issues Hermes files are public. The skill forbids secrets in issue text and treats GitHub content from anyone but `kjsb25`/bots as untrusted data.
- Known gap: the socket proxy allows `docker inspect`, which exposes every container's env vars (most of `.env`). Hermes inherits this, as does `claude-dev`.

**First-run setup:**

*A. Accounts (phone/browser)*
1. **OpenRouter** → Keys → Create key `hermes-nova` with a **credit limit** (e.g. $15). Settings → Privacy: disable prompt logging/training. Optionally also set the account-wide allowed providers to DeepInfra, Together, Parasail as a second lock. Don't enable auto top-up.
2. **GitHub** → Settings → Developer settings → Fine-grained tokens → resource owner `nova-firefly`, Repository access **All repositories** → Issues: Read & write; Contents, Pull requests, Actions: Read-only. (It can also read any public repo, including `kjsb25`'s; `kjsb25` private repos would need a separate token.)
3. **A second phone number for the bot** that can receive one SMS or voice call: a Google Voice number (free, US) usually works, or a cheap prepaid SIM. Don't use your own number.

*B. Claude Code Action (any machine with Claude Code logged in to your plan)*
```bash
claude setup-token                       # prints a long-lived OAuth token
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R nova-firefly/nova-config   # paste it
```
Then install the Claude GitHub App on the repo (https://github.com/apps/claude) — the action uses it to comment and push.

*C. Host*
```bash
cd ~/nova-config && git pull
# .env: fill the HERMES_* block (see .env.example)
docker volume create hermes_data
docker volume create hermes_signal_data

# Register the bot's Signal number (one-time). Captcha: open
# https://signalcaptchas.org/registration/generate.html in a browser, solve it,
# then copy the "Open Signal" link (signalcaptcha://...) — long-press it on a phone.
cd hermes
docker compose run --rm --no-deps signal-cli -a +1BOTNUMBER register --captcha 'signalcaptcha://...'
#   (no SMS after ~1 min? re-run register with --voice to get a call instead)
docker compose run --rm --no-deps signal-cli -a +1BOTNUMBER verify 123456
docker compose run --rm --no-deps signal-cli -a +1BOTNUMBER updateProfile --given-name Hermes
cd ..

./nova.sh up hermes
docker logs -f hermes        # wait for the dashboard + gateway to come up

# One-time: disable the bundled self-coding skills (skills.* can't be managed)
docker exec hermes hermes config set skills.disabled '["claude-code","codex"]'

# One-time (and on token rotation): GitHub PAT into Hermes' own .env, where the
# built-in github skill's gh-env.sh reads it (env vars GH_TOKEN/GITHUB_TOKEN are
# always stripped from the agent's shell, so a compose env var would not work)
docker exec hermes hermes config set GITHUB_TOKEN "$(grep '^HERMES_GITHUB_TOKEN=' .env | cut -d= -f2)"
docker restart hermes

# Optional check — header should name /etc/hermes/config.yaml and list the pinned keys
docker exec hermes hermes config
```

Model and provider routing need no post-up commands: they come from `hermes/managed/config.yaml`, mounted read-only as Hermes' **managed scope** (`/etc/hermes/config.yaml`). Managed keys win over the user config and env, and Hermes refuses to change them (dashboard, `hermes config set`, or the agent itself). To change one, edit the file and `./nova.sh recreate hermes`.

*D. Smoke test*
1. `https://hermes.${NOVA_DOMAIN}` → Authelia → Hermes login → dashboard loads.
2. In Signal, message the bot's number "hi" → it replies. From any other number → no reply.
3. OpenRouter → Activity: requests show provider DeepInfra/Together/Parasail.
4. DM: "Ask Claude to fix a typo in context/stacks.md" → issue appears starting `@claude`, the **Claude Code** workflow runs, Claude comments with a branch/PR.
5. Approval allowlist (dashboard): add read-only docker verbs (`docker ps*`, `docker logs*`, `docker inspect*`, `docker stats*`) so troubleshooting doesn't prompt every time.

**Cost:** Hermes only spends tokens when messaged or when a cron job fires; idle is free. Expect ~$5–15/month for light daily use; the OpenRouter key limit is the hard ceiling. Claude Code Action runs count against your Claude plan's usage limits.

---

## Shared Infrastructure

### Networks (pre-created externally)
- `traefik_default` — all internet-facing services; created by `nova.sh up` if missing
- `wud_default` — WUD and watched services
- `media` — internal network for *arr suite + gluetun
- `internal_webhook` — `internal: true` network shared between `internal-webhook` (media stack) and authorised caller containers (currently `movienight-backend`); no internet egress; created by `nova.sh up` if missing

### Homepage Dashboard Groups
Services appear on homepage grouped by their `homepage.group` label:
- Infrastructure, Media, Downloads, Tools, Development, Home Automation

### traefik/dynamic.yaml
Routes for host-mode services that Docker provider can't discover, plus global middleware definitions:
- `ha.NOVA_DOMAIN` → `host.docker.internal:8123` (Home Assistant)
- `ma.NOVA_DOMAIN` → `host.docker.internal:8095` (Music Assistant)
- `glances.NOVA_DOMAIN` → `host.docker.internal:61208` (Glances) — protected by `authelia@file`
- `authelia` middleware — forwardAuth to `http://authelia:9091/api/authz/forward-auth`
- Per-service `sablier-<service>` middlewares — one per on-demand container for independent wake/sleep lifecycles: `sablier-stirling-pdf`, `sablier-vikunja`, `sablier-snapotter`, `sablier-immich-power-tools`, `sablier-homescreen-hero`
- `actual-mcp-sse` middleware — rate limit for the public Actual Budget MCP (SSE) route (not behind Authelia; bearer-token auth). See `context/actual-mcp.md`.
- `sablier-movienight-test` middleware — intentional shared group: frontend + backend wake together (the app is unusable without both)
