# Stack & Service Inventory

All stacks managed via `./nova.sh`. Stack order in `ALL_STACKS` (nova.sh:27) controls startup order.

## Stack Summary

| Stack | File | Services |
|-------|------|----------|
| infra | docker-compose.infra.yaml | traefik, homepage, arcane, duckdns, glances, volume-sharer, wud |
| media | docker-compose.media.yaml | plex, radarr, sonarr, bazarr, prowlarr, tautulli, overseerr, gluetun, transmission |
| immich | docker-compose.immich.yaml | immich-server, immich-machine-learning, immich-postgres, immich-redis |
| home | docker-compose.home.yaml | homeassistant, zwave-js-ui, music-assistant |
| movienight | docker-compose.movienight.yaml | movienight-frontend, movienight-backend, movienight-db |
| dev | docker-compose.dev.yaml | vibe-kanban |
| tools | docker-compose.tools.yaml | stirling-pdf, vikunja |
| backup | docker-compose.backup.yaml | backrest, duplicati |
| gaming | docker-compose.gaming.yaml | minecraft |

---

## infra stack (`docker-compose.infra.yaml`)

**Purpose:** Core infrastructure — reverse proxy, DNS, dashboard, monitoring, updates

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| traefik | traefik:v3.6 | 80, 443 | traefik.NOVA_DOMAIN | Wildcard TLS via DuckDNS DNS-01 challenge |
| homepage | ghcr.io/gethomepage/homepage | 3000 | home.NOVA_DOMAIN | Dashboard; reads Docker labels + ./homepage/ config |
| arcane | ghcr.io/getarcaneapp/arcane | 3552 | arcane.NOVA_DOMAIN | Container management UI |
| duckdns | lscr.io/linuxserver/duckdns | — | — | Dynamic DNS updater |
| glances | nicolargo/glances:latest-full | 61208 (host) | glances.NOVA_DOMAIN | System monitor; host network mode → routed via traefik/dynamic.yaml |
| volume-sharer | gdiepen/volume-sharer | 139, 445 (host) | — | Samba share of Docker volumes |
| wud | getwud/wud | 3003→3000 | wud.NOVA_DOMAIN | Watch Update Docker; triggers per-stack docker-compose pull+up |

**External volumes:** `traefik_acme`, `volume_sharer_samba_config`, `arcane_data`

**External networks:** `traefik_default` (shared), `wud_default`

**WUD triggers configured (in wud service env):** infra, media, backup, movienight stacks

---

## media stack (`docker-compose.media.yaml`)

**Purpose:** Media server and content acquisition pipeline

| Service | Image | Port(s) | URL | Notes |
|---------|-------|---------|-----|-------|
| plex | ghcr.io/linuxserver/plex | 32400 | plex.NOVA_DOMAIN | Media server; NVIDIA GPU passthrough |
| radarr | ghcr.io/linuxserver/radarr | 7878 | radarr.NOVA_DOMAIN | Movie management; on `media` network |
| sonarr | ghcr.io/linuxserver/sonarr | 8989 | sonarr.NOVA_DOMAIN | TV show management; on `media` network |
| bazarr | lscr.io/linuxserver/bazarr | 6767 | bazarr.NOVA_DOMAIN | Subtitle management |
| prowlarr | lscr.io/linuxserver/prowlarr | 9696 | prowlarr.NOVA_DOMAIN | Indexer aggregator; on `media` network |
| tautulli | ghcr.io/tautulli/tautulli | 8181 | tautulli.NOVA_DOMAIN | Plex stats/monitoring |
| overseerr | lscr.io/linuxserver/overseerr | 5055 | overseerr.NOVA_DOMAIN | Media request management |
| gluetun | qmcgaw/gluetun | 9094→9091, 6789 | transmission.NOVA_DOMAIN, nzbget.NOVA_DOMAIN | Mullvad WireGuard VPN gateway; Traefik routes transmission + nzbget through it |
| transmission | lscr.io/linuxserver/transmission | (via gluetun) | — | Torrent client; `network_mode: service:gluetun` |
| nzbget | ghcr.io/nzbgetcom/nzbget | (via gluetun) | nzbget.NOVA_DOMAIN | Usenet downloader; `network_mode: service:gluetun` |

**Key:** transmission and nzbget run inside gluetun's network namespace (`network_mode: service:gluetun`). Traefik labels are on gluetun, not the sidecars.

**Media paths:** `/data1`, `/data2`, `/data3` — mounted directly (not volumes) for media libraries

**External volumes:** `bazarr_config`, `gluetun_data`, `nzbget_config`, `nzbget_data`, `overseerr_config`, `radarr_config`, `sonarr_config`, `tautulli_config`, `transmission_config`, `transmission_data`

**Required env:** `PUID`, `PGID`, `TZ`, `PLEX_CLAIM_TOKEN`, `MULLVAD_WIREGUARD_PRIVATE_KEY`, `MULLVAD_WIREGUARD_ADDRESSES`, `TRANSMISSION_USER`, `TRANSMISSION_PASS`, `NZBGET_USER`, `NZBGET_PASS`

---

## immich stack (`docker-compose.immich.yaml`)

**Purpose:** Photo/video management with ML-based organization

| Service | Image | Notes |
|---------|-------|-------|
| immich-server | ghcr.io/immich-app/immich-server | Main app |
| immich-machine-learning | ghcr.io/immich-app/immich-machine-learning | ML inference |
| immich-postgres | tensorchord/pgvecto-rs | PostgreSQL with vector extension |
| immich-redis | redis | Cache |

**Required env:** `IMMICH_DB_PASSWORD`, `UPLOAD_LOCATION`, `DB_DATA_LOCATION`, `DB_USERNAME`, `DB_DATABASE_NAME`

---

## home stack (`docker-compose.home.yaml`)

**Purpose:** Home automation and smart devices

| Service | Notes |
|---------|-------|
| homeassistant | Core home automation platform |
| zwave-js-ui | Z-Wave device management |
| music-assistant | Music streaming; host network mode → routed via traefik/dynamic.yaml at `ma.NOVA_DOMAIN:8095` |

**Required env:** `ZWAVE_SESSION_SECRET`

---

## movienight stack (`docker-compose.movienight.yaml`)

**Purpose:** Movie suggestion web app (custom-built)

| Service | Image/Build | Notes |
|---------|-------------|-------|
| movienight-frontend | ghcr.io/kjsb25/movienight:latest | React frontend; routes all non-/graphql traffic |
| movienight-backend | build: ./movienight/backend | GraphQL API on port 4000 |
| movienight-db | postgres:15-alpine | Internal network only |

**Network:** `movienight_internal` (internal: true) isolates DB from Traefik

**Routing:** Traefik routes `/graphql` to backend, everything else to frontend — both on `movienight.NOVA_DOMAIN`

**Submodule:** `movienight/` directory is a git submodule. Initialize with `git submodule update --init`

**Required env:** `MOVIENIGHT_DB_PASSWORD`

---

## dev stack (`docker-compose.dev.yaml`)

**Purpose:** Development environment

| Service | Notes |
|---------|-------|
| vibe-kanban | Node.js 22 container with Claude Code CLI, gh CLI, Docker CLI; ports 4000, 4001 |

**Required env:** `GH_TOKEN`

---

## tools stack (`docker-compose.tools.yaml`)

| Service | Notes |
|---------|-------|
| stirling-pdf | PDF manipulation tool |
| vikunja | Task management |

---

## backup stack (`docker-compose.backup.yaml`)

| Service | Notes |
|---------|-------|
| backrest | Restic-based backup manager |
| duplicati | Backup with cloud support |

**Required env:** `DUPLICATI_SETTINGS_ENCRYPTION_KEY`

---

## gaming stack (`docker-compose.gaming.yaml`)

| Service | Notes |
|---------|-------|
| minecraft | Minecraft server |

---

## Shared Infrastructure

### Networks (pre-created externally)
- `traefik_default` — all internet-facing services; created by `nova.sh up` if missing
- `wud_default` — WUD and watched services
- `media` — internal network for *arr suite + gluetun

### Homepage Dashboard Groups
Services appear on homepage grouped by their `homepage.group` label:
- Infrastructure, Media, Downloads, Tools, Development, Home Automation

### traefik/dynamic.yaml
Routes for host-mode services that Docker provider can't discover:
- `ma.NOVA_DOMAIN` → `host.docker.internal:8095` (Music Assistant)
- `glances.NOVA_DOMAIN` → `host.docker.internal:61208` (Glances)
