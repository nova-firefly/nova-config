# Stack & Service Inventory

All stacks managed via `./nova.sh` (or via the Dockge UI at `dockge.${NOVA_DOMAIN}`). Stack order in `ALL_STACKS` (nova.sh) controls startup order. Each stack lives in its own directory containing `compose.yaml` and a `.env` symlink to the shared root `.env`.

## Stack Summary

| Stack | File | Services |
|-------|------|----------|
| infra | infra/compose.yaml | traefik, homepage, arcane, dockge, duckdns, glances, volume-sharer, wud, scrutiny, socket-proxy |
| authelia | authelia/compose.yaml | authelia, redis |
| media | media/compose.yaml | plex, radarr, sonarr, bazarr, prowlarr, tautulli, seerr, kometa, kometa-quickstart, internal-webhook, gluetun, qbittorrent, decluttarr, recyclarr, homescreen-hero |
| immich | immich/compose.yaml | immich-server, immich-machine-learning, immich-postgres, immich-redis, immich-power-tools |
| home | home/compose.yaml | homeassistant, zwave-js-ui, music-assistant, matter-server |
| movienight | movienight/compose.yaml | movienight-frontend, movienight-backend, movienight-db |
| dev | dev/compose.yaml | vibe-kanban, vibe-kanban-tools |
| tools | tools/compose.yaml | actual, stirling-pdf, vikunja, uptime-kuma, ntfy |
| backup | backup/compose.yaml | backrest |
| gaming | gaming/compose.yaml | pterodactyl-db, pterodactyl-cache, pterodactyl-panel, pterodactyl-wings |
| movienight-test | movienight-test/compose.yaml | (CI-only; excluded from reconcile) |
| strava-hevy | strava-hevy/compose.yaml | strava-hevy |

---

## infra stack (`infra/compose.yaml`)

**Purpose:** Core infrastructure — reverse proxy, DNS, dashboard, monitoring, updates

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| traefik | traefik:v3.6 | 80, 443 | traefik.NOVA_DOMAIN | Wildcard TLS via DuckDNS DNS-01 challenge |
| homepage | ghcr.io/gethomepage/homepage | 3000 | home.NOVA_DOMAIN | Dashboard; reads Docker labels + `../homepage/` config (root-level dir) |
| arcane | ghcr.io/getarcaneapp/arcane | 3552 | arcane.NOVA_DOMAIN | Container management UI (per-container) |
| dockge | louislam/dockge:1 | 5001 | dockge.NOVA_DOMAIN | Compose stack manager (per-stack); mobile-friendly; reads/writes `<stack>/compose.yaml` on disk via `${NOVA_CONFIG_PATH}:/opt/stacks` mount |
| duckdns | lscr.io/linuxserver/duckdns | — | — | Dynamic DNS updater |
| glances | nicolargo/glances:latest-full | 61208 (host) | glances.NOVA_DOMAIN | System monitor; host network mode → routed via traefik/dynamic.yaml |
| volume-sharer | gdiepen/volume-sharer | 139, 445 (host) | — | Samba share of Docker volumes |
| wud | getwud/wud | 3003→3000 | wud.NOVA_DOMAIN | Watch Update Docker; notify-only (Discord). Manual deploys via Dockge / Arcane / `nova.sh update` |
| scrutiny | ghcr.io/analogj/scrutiny:master-omnibus | 8082→8080 | scrutiny.NOVA_DOMAIN | S.M.A.R.T. hard drive health monitoring; needs SYS_RAWIO + device passthrough |

**External volumes:** `traefik_acme`, `samba_config`, `arcane_data`, `scrutiny_data`, `dockge_data`

**Config files (bind-mounted):** `../scrutiny/scrutiny.yaml` (root-level `scrutiny/` dir; path is `..` from the infra stack dir)

**External networks:** `traefik_default` (shared)

**WUD mode:** notify-only (Discord). Manual deploys via Arcane UI or `nova.sh update`.

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
| homescreen-hero | trentferguson/homescreen-hero | 8000 | homescreen-hero.NOVA_DOMAIN | Plex dashboard: collection rotation, Tautulli/Seerr widgets, watch history tools |
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
| immich-power-tools | ghcr.io/immich-power-tools/immich-power-tools | Library organizer UI — face merge, album suggestions, analytics; at `immich-power-tools.NOVA_DOMAIN` |

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
| movienight-frontend | ghcr.io/kjsb25/movienight:latest | React frontend; routes all non-/graphql traffic |
| movienight-backend | ghcr.io/kjsb25/movienight-backend:latest | GraphQL API on port 4000; built by CI in movienight repo |
| movienight-db | postgres:15-alpine | Internal network only |

**Networks:** `movienight_internal` (internal: true) isolates DB from Traefik; `internal_webhook` (external, internal: true) connects backend to `internal-webhook` in media stack

**Routing:** Traefik routes `/graphql` to backend, everything else to frontend — both on `movienight.NOVA_DOMAIN`

**Auto-deploy:** Both images are built by CI in the `kjsb25/movienight` repo on push to `master` and pushed to GHCR. The CI's SSH deploy job calls `nova.sh update movienight` after the image push. WUD watches both images and notifies on Discord when digests change but does not recreate.

**Submodule:** lives at `movienight/src/` (the `movienight/` dir itself is the stack dir holding `compose.yaml`). Kept for local development reference only — no longer used for production builds. Initialize with `git submodule update --init`.

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
| actual | actualbudget/actual-server | 5006 | actual.NOVA_DOMAIN | Personal budgeting |
| stirling-pdf | stirlingtools/stirling-pdf | 8080 | stirling-pdf.NOVA_DOMAIN | PDF manipulation tool |
| vikunja | vikunja/vikunja | 3456 | vikunja.NOVA_DOMAIN | Task management |
| uptime-kuma | louislam/uptime-kuma | 3002→3001 | status.NOVA_DOMAIN | Service uptime monitoring and alerting |
| ntfy | binwiederhier/ntfy | 80 | ntfy.NOVA_DOMAIN | Push notification server; no Authelia — must be reachable by webhooks. Also used by nova.sh to notify on up/down/update/recreate/restart (topic: `$NTFY_TOPIC`) |

**External volumes:** `stirling_config`, `uptime_kuma_data`, `vikunja_db`, `vikunja_files`, `ntfy_data`

**Compose-managed volumes:** `actual_data` (named `tools_actual_data` by Docker Compose)

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
| pterodactyl-db | mariadb:11 | — | — | MariaDB for panel; internal network only |
| pterodactyl-cache | redis:7-alpine | — | — | Redis cache/sessions; internal network only |
| pterodactyl-panel | ghcr.io/pterodactyl/panel:latest | 80 | pterodactyl.NOVA_DOMAIN | Web-based game server management panel |
| pterodactyl-wings | ghcr.io/pterodactyl/wings:latest | 8080 (via Traefik), 2022 | wings.NOVA_DOMAIN | Game server daemon; privileged + Docker socket |

**Networks:** `gaming_internal` (internal: true) isolates DB + cache; `traefik_default` for panel and wings

**External volumes:** `pterodactyl_db`, `pterodactyl_panel_var`, `pterodactyl_panel_logs`

**Config files (bind-mounted):** `../pterodactyl/config.yml` (root-level dir) — Wings node config generated by the panel on first setup

**Required env:** `PTERODACTYL_DB_PASSWORD`, `PTERODACTYL_DB_ROOT_PASSWORD`, `PTERODACTYL_APP_KEY`, `PTERODACTYL_HASHIDS_SALT`, `PTERODACTYL_APP_SERVICE_AUTHOR`

**Updates:** WUD watches panel and wings images and sends Discord notifications; deploys are manual.

**Note:** Wings runs with `privileged: true` and the host Docker socket mounted. It creates game server containers directly on the host Docker daemon. Game servers (including Minecraft) are managed through the Pterodactyl panel.

**First-run setup:**
```bash
# 1. Create external volumes
docker volume create pterodactyl_db
docker volume create pterodactyl_panel_var
docker volume create pterodactyl_panel_logs

# 2. Create Wings config directory at repo root
mkdir -p pterodactyl

# 3. Start the stack (Wings will restart-loop until config.yml is placed)
./nova.sh up gaming

# 4. Create admin user
docker exec -it pterodactyl-panel php artisan p:user:make

# 5. In panel admin: Settings → Nodes → Create Node
#    FQDN: wings.NOVA_DOMAIN  Scheme: https  Port: 443  Daemon SFTP: 2022
#    Copy the generated config block → save to pterodactyl/config.yml (at repo root)

# 6. Wings picks up config.yml on next restart and connects to the panel
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
