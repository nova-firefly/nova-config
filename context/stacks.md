# Stack & Service Inventory

All stacks managed via `./nova.sh` (or via the Dockge UI at `dockge.${NOVA_DOMAIN}`). Stack order in `ALL_STACKS` (nova.sh) controls startup order. Each stack lives in its own directory containing `compose.yaml` and a `.env` symlink to the shared root `.env`.

## Stack Summary

| Stack | File | Services |
|-------|------|----------|
| infra | infra/compose.yaml | traefik, homepage, arcane, dockge, duckdns, glances, volume-sharer, wud, scrutiny, socket-proxy, socket-proxy-sablier, sablier, runners-socket-proxy, nova-config-sync, runner-nova-config, runner-vibe-kanban-tools, runner-movienight, runner-todoassist |
| authelia | authelia/compose.yaml | authelia, redis |
| media | media/compose.yaml | plex, radarr, sonarr, bazarr, prowlarr, tautulli, seerr, kometa, kometa-quickstart, internal-webhook, gluetun, qbittorrent, decluttarr, recyclarr, homescreen-hero |
| immich | immich/compose.yaml | immich-server, immich-machine-learning, immich-postgres, immich-redis, immich-power-tools |
| home | home/compose.yaml | homeassistant, zwave-js-ui, music-assistant, matter-server |
| movienight | movienight/compose.yaml | movienight-frontend, movienight-backend, movienight-db |
| dev | dev/compose.yaml | vibe-kanban, vibe-kanban-tools |
| tools | tools/compose.yaml | actual, stirling-pdf, vikunja, uptime-kuma, ntfy, snapotter, shell |
| backup | backup/compose.yaml | backrest |
| gaming | gaming/compose.yaml | minecraft |
| movienight-test | movienight-test/compose.yaml | movienight-test-frontend, movienight-test-backend, movienight-test-db (CI-only; excluded from reconcile). Frontend + backend are **on-demand via Sablier** (group `movienight-test`, 60m idle); DB stays running. |
| strava-hevy | strava-hevy/compose.yaml | strava-hevy |
| todoassist | todoassist/compose.yaml | todoassist |

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
| sablier | sablierapp/sablier:1.15.0 | 10000 (internal only) | — | On-demand container controller: stops idle containers, wakes them on the next HTTP request via a Traefik plugin. Target services opt in with `sablier.enable=true` + `sablier.group=<name>` labels plus the `sablier-tools@file` middleware. See `context/patterns.md` for the pattern. Plugin version pinned in traefik's static args (`v1.3.0`) and daemon image tag must stay compatible. |
| runners-socket-proxy | tecnativa/docker-socket-proxy | — | — | Write-allowlist socket proxy for self-hosted runners (POST=1, EXEC=0, BUILD=0, SECRETS=0, SYSTEM=0); reachable only on `runners_net` |
| nova-config-sync | alpine/git (pinned digest) | — | — | Sole writer to `/srv/nova-config`; loops `git fetch && reset --hard origin/main` every 10 min. Replaces the deleted `.github/workflows/sync.yml` Actions round-trip |
| runner-nova-config | myoung34/github-runner (pinned digest) | — | — | Ephemeral self-hosted runner for `nova-firefly/nova-config`; labels `nova,nova-config`; jobs launch via `runners-socket-proxy` |
| runner-vibe-kanban-tools | myoung34/github-runner (pinned digest) | — | — | Ephemeral runner for `nova-firefly/vibe-kanban-tools`; labels `nova,vibe-kanban-tools` |
| runner-movienight | myoung34/github-runner (pinned digest) | — | — | Ephemeral runner for `nova-firefly/movienight`; serves both prod and test via labels `nova,movienight,movienight-test` (one runner per repo, not per environment) |

**External volumes:** `traefik_acme`, `samba_config`, `arcane_data`, `scrutiny_data`, `dockge_data`

**Config files (bind-mounted):** `../scrutiny/scrutiny.yaml` (root-level `scrutiny/` dir; path is `..` from the infra stack dir)

**External networks:** `traefik_default` (shared)

**Compose-managed networks:** `runners_net` (bridge, not internal — carries runner ↔ proxy traffic and gives runners outbound internet for GitHub long-poll), `sablier_internal` (bridge, `internal: true` — sablier ↔ socket-proxy-sablier only, no egress)

**Compose-managed volumes:** `runner_nova_config_state`, `runner_vibe_kanban_tools_state`, `runner_movienight_state` — per-runner registration state so ephemeral runners don't re-register on every restart

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

**Media paths:** `/data1`, `/data2`, `/data3` — mounted directly (not volumes) for media libraries

**Download paths in arr services:** torrents at `/downloads` (qbittorrent_data)

**External volumes:** `bazarr_config`, `gluetun_data`, `homescreen_hero_data`, `overseerr_config` (aliased as `seerr_config`), `prowlarr_config`, `qbittorrent_config`, `qbittorrent_data`, `radarr_config`, `sonarr_config`, `tautulli_config`

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

**Image:** Both images are built by CI in [`nova-firefly/movienight`](https://github.com/nova-firefly/movienight) on push to `main` and published to GHCR. The CI's SSH deploy job calls `nova.sh update movienight` after the image push. WUD watches the digest of `:latest` and notifies on Discord; redeploy with `./nova.sh update movienight`.

**Required env:** `MOVIENIGHT_DB_PASSWORD`

---

## dev stack (`dev/compose.yaml`)

**Purpose:** Development environment

| Service | Image/Build | Notes |
|---------|-------------|-------|
| vibe-kanban | local build (`../vibe-kanban`) | Node.js 22 container with Claude Code CLI, gh CLI, Docker CLI; ports 4000, 4001 |
| vibe-kanban-tools | ghcr.io/kjsb25/vibe-kanban-tools:latest | Next.js quick-capture task UI for Vibe Kanban; port 3000 |

**Auto-deploy (vibe-kanban-tools):** Image is built by CI in the `kjsb25/vibe-kanban-tools` repo on push to `main` and pushed to GHCR. The CI deploy job SSH-deploys immediately via `nova.sh update dev`. WUD watches the image and notifies on Discord when the digest changes but does not recreate.

**Required env:** `GH_TOKEN`, `VIBE_KANBAN_API_KEY`, `VIBE_KANBAN_TOOLS_SUBMIT_TOKEN`

**Required GitHub secrets (vibe-kanban-tools repo):** `NOVA_HOST`, `NOVA_USER`, `NOVA_SSH_KEY`

---

## tools stack (`tools/compose.yaml`)

| Service | Image | Port | URL | Notes |
|---------|-------|------|-----|-------|
| actual | actualbudget/actual-server | 5006 | actual.NOVA_DOMAIN | Personal budgeting. **On-demand via Sablier** (group `tools`, 60m idle). |
| stirling-pdf | stirlingtools/stirling-pdf | 8080 | stirling-pdf.NOVA_DOMAIN | PDF manipulation tool. **On-demand via Sablier** (group `tools`, 60m idle); JVM cold start — `start_period` bumped to 60s so wake doesn't briefly flip to unhealthy. |
| vikunja | vikunja/vikunja | 3456 | vikunja.NOVA_DOMAIN | Task management. **On-demand via Sablier** (group `tools`, 60m idle). Assumes browser-only usage; if CalDAV subscribers or the mobile app poll the host, they'll keep it warm — revert this service and remove sablier labels. |
| uptime-kuma | louislam/uptime-kuma | 3002→3001 | status.NOVA_DOMAIN | Service uptime monitoring and alerting |
| ntfy | binwiederhier/ntfy | 80 | ntfy.NOVA_DOMAIN | Push notification server; no Authelia — must be reachable by webhooks. Also used by nova.sh to notify on up/down/update/recreate/restart (topic: `$NTFY_TOPIC`) |
| snapotter | ghcr.io/snapotter-hq/snapotter | 1349 | snapotter.NOVA_DOMAIN | Self-hosted image manipulation (50+ tools, local AI). Behind Authelia; internal auth also on with default `admin`/`admin` (change on first login). `/tmp/workspace` is a compose-managed volume — auto-cleaned by the app. **On-demand via Sablier** (group `tools`, 60m idle; see patterns.md). Cold-start ~60s. |
| shell | local build (`../shell/`) | 7681 | shell.NOVA_DOMAIN | Browser SSH terminal to host. ttyd (alpine) + openssh-client; reaches host sshd via `host.docker.internal:22` (docker bridge gateway). No SSH creds in the image — user types host secret in browser. |

**External volumes:** `stirling_config`, `uptime_kuma_data`, `vikunja_db`, `vikunja_files`, `ntfy_data`, `snapotter_data`

**Compose-managed volumes:** `actual_data` (named `tools_actual_data` by Docker Compose), `snapotter_workspace` (ephemeral processing dir; safe to wipe)

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
- `sablier-tools` middleware — on-demand container wake for group `tools` (actual, stirling-pdf, vikunja, snapotter, immich-power-tools, homescreen-hero)
- `sablier-movienight-test` middleware — on-demand container wake for group `movienight-test` (frontend + backend)
