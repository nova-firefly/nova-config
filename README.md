# Nova Compose Files

Docker Compose configuration for managing self-hosted services.

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

4. Validate configuration:
   ```bash
   docker-compose config
   ```

5. Start services:
   ```bash
   docker-compose up -d
   ```

## Security Notes

- **NEVER** commit the `.env` file to version control
- Store `.env` backup securely (encrypted password manager)
- Rotate credentials periodically
- Review `.gitignore` before committing new files
- Use `docker-compose config` to verify variable substitution

## Obtaining Credentials

- **DuckDNS Token**: https://www.duckdns.org/
- **Plex Claim Token**: https://www.plex.tv/claim/ (expires in 4 minutes)
- **Mullvad VPN**: https://mullvad.net/account/

## Troubleshooting

If a service fails to start:
1. Check environment variables: `docker-compose config`
2. Review service logs: `docker-compose logs [service-name]`
3. Verify .env file syntax (no spaces around `=`)
4. Ensure all required variables are set in .env

## Services

This configuration manages 25+ self-hosted services including:
- Immich (photo management)
- Plex (media server)
- Transmission (torrent client with VPN)
- Duplicati (backup service)
- DuckDNS (dynamic DNS)
- Z-Wave JS UI (smart home control)
- And many more...