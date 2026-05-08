# Nova Compose Files

Docker Compose configuration for managing self-hosted services, split into independent stacks.

## Stacks

| Stack | File | Services |
|-------|------|----------|
| **Media** | `media/compose.yaml` | Plex, Radarr, Sonarr, Bazarr, Prowlarr, Tautulli, Seerr, Kometa, qBittorrent (Gluetun VPN) |
| **Immich** | `immich/compose.yaml` | Immich Server, Machine Learning, Postgres, Redis |
| **Home** | `home/compose.yaml` | Home Assistant, Z-Wave JS UI, Music Assistant, Matter |
| **Infra** | `infra/compose.yaml` | Traefik, Authelia (separate stack), Arcane, Dockge, WUD, DuckDNS, Homepage, Glances, Scrutiny |
| **Authelia** | `authelia/compose.yaml` | Authelia + Redis (forward-auth for protected services) |
| **Backup** | `backup/compose.yaml` | Backrest, Duplicati |
| **Gaming** | `gaming/compose.yaml` | Pterodactyl panel + Wings |
| **Dev** | `dev/compose.yaml` | Vibe Kanban, Vibe Kanban Tools |
| **Tools** | `tools/compose.yaml` | Stirling PDF, Vikunja, Uptime Kuma, ntfy, Actual |
| **Movienight** | `movienight/compose.yaml` | Frontend + Backend + Postgres |

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

4. Start all stacks:
   ```bash
   ./nova.sh up
   ```

## Managing Stacks

```bash
./nova.sh up                    # Start all stacks
./nova.sh up media              # Start a specific stack
./nova.sh down                  # Stop all stacks
./nova.sh logs media -f         # View logs for a stack
./nova.sh update infra          # Pull + restart a stack
./nova.sh config media          # Validate a stack
```

## Environment Variables

See `.env.example` for all required variables. Each variable is annotated with which stack uses it.

| Variable | Stack | Source |
|----------|-------|--------|
| `DUCKDNS_TOKEN` | infra | https://www.duckdns.org/ |
| `DUPLICATI_SETTINGS_ENCRYPTION_KEY` | backup | `openssl rand -base64 32` |
| `IMMICH_DB_PASSWORD` | immich | `openssl rand -base64 24` |
| `PLEX_CLAIM_TOKEN` | media | https://www.plex.tv/claim/ |
| `WIREGUARD_PRIVATE_KEY` | media | https://mullvad.net/account/ (Gluetun) |
| `WIREGUARD_ADDRESSES` | media | https://mullvad.net/account/ (Gluetun) |
| `ZWAVE_SESSION_SECRET` | home | `openssl rand -base64 32` |

## Security Notes

- **NEVER** commit the `.env` file to version control
- Store `.env` backup securely (encrypted password manager)
- Rotate credentials periodically
- Review `.gitignore` before committing new files

## Troubleshooting

If a service fails to start:
1. Check environment variables: `./nova.sh config <stack>`
2. Review service logs: `./nova.sh logs <stack>`
3. Verify .env file syntax (no spaces around `=`)
4. Ensure all required variables are set in .env
