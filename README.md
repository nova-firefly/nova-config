# Nova Compose Files

Docker Compose configuration for managing self-hosted services, split into independent stacks.

## Stacks

| Stack | File | Services |
|-------|------|----------|
| **Media** | `docker-compose.media.yaml` | Plex, Radarr, Sonarr, Bazarr, Prowlarr, Transmission (VPN), Tautulli, Overseerr |
| **Immich** | `docker-compose.immich.yaml` | Immich Server, Machine Learning, Postgres, Redis |
| **Home** | `docker-compose.home.yaml` | Home Assistant, Z-Wave JS UI, Music Assistant |
| **Infra** | `docker-compose.infra.yaml` | Traefik, Portainer, Dockge, WUD, DuckDNS, Homepage, Volume Sharer |
| **Backup** | `docker-compose.backup.yaml` | Backrest, Duplicati |
| **Gaming** | `docker-compose.gaming.yaml` | Minecraft |
| **Dev** | `docker-compose.dev.yaml` | Vibe Kanban |

## Prerequisites

- Docker and Docker Compose installed
- Access to required service credentials

## Initial Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/kjsb25/nova-config.git
   cd nova-config
   ```

2. Create environment file:
   ```bash
   cp .env.example .env
   ```

3. Edit .env and fill in your credentials:
   ```bash
   nano .env  # or your preferred editor
   ```

4. Start a specific stack:
   ```bash
   docker compose -f docker-compose.media.yaml up -d
   ```

5. Start all stacks:
   ```bash
   for f in docker-compose.*.yaml; do docker compose -f "$f" up -d; done
   ```

## Managing Stacks

```bash
# Start a stack
docker compose -f docker-compose.media.yaml up -d

# Stop a stack
docker compose -f docker-compose.media.yaml down

# View logs for a stack
docker compose -f docker-compose.media.yaml logs -f

# Update images for a stack
docker compose -f docker-compose.media.yaml pull && docker compose -f docker-compose.media.yaml up -d

# Validate a stack
docker compose -f docker-compose.media.yaml config
```

## Environment Variables

See `.env.example` for all required variables. Each variable is annotated with which stack uses it.

| Variable | Stack | Source |
|----------|-------|--------|
| `DUCKDNS_TOKEN` | infra | https://www.duckdns.org/ |
| `DUPLICATI_SETTINGS_ENCRYPTION_KEY` | backup | `openssl rand -base64 32` |
| `IMMICH_DB_PASSWORD` | immich | `openssl rand -base64 24` |
| `PLEX_CLAIM_TOKEN` | media | https://www.plex.tv/claim/ |
| `TRANSMISSION_OPENVPN_USERNAME` | media | https://mullvad.net/account/ |
| `TRANSMISSION_OPENVPN_PASSWORD` | media | https://mullvad.net/account/ |
| `ZWAVE_SESSION_SECRET` | home | `openssl rand -base64 32` |

## Security Notes

- **NEVER** commit the `.env` file to version control
- Store `.env` backup securely (encrypted password manager)
- Rotate credentials periodically
- Review `.gitignore` before committing new files

## Troubleshooting

If a service fails to start:
1. Check environment variables: `docker compose -f <stack-file> config`
2. Review service logs: `docker compose -f <stack-file> logs [service-name]`
3. Verify .env file syntax (no spaces around `=`)
4. Ensure all required variables are set in .env
