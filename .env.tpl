# .env.tpl - 1Password secrets template for nova-config
# Generates .env by running: ./nova.sh secrets-refresh
# op:// references are resolved via the local 1Password Connect Server.
#
# Rules:
#   - Actual secrets use op://Nova Homelab/<Item>/<field> format
#   - Non-secret config is hardcoded here (edit this file directly for those)
#   - OP_CONNECT_TOKEN is NOT in this file — it lives only in .env (bootstrap key)
#   - PLEX_CLAIM_TOKEN expires in 4 min — get a fresh one at plex.tv/claim before first deploy

#################################################
# Shared Settings
#################################################
TZ=America/Chicago
PUID=1000
PGID=1000
NOVA_HOSTNAME=nova
NOVA_USER_HOME=/home/your-username
NOVA_CONFIG_PATH=/home/your-username/nova-config

#################################################
# Authelia - Authentication Portal
# 1P Item: Authelia
#################################################
AUTHELIA_JWT_SECRET=op://Nova Homelab/Authelia/jwt-secret
AUTHELIA_SESSION_SECRET=op://Nova Homelab/Authelia/session-secret
AUTHELIA_STORAGE_ENCRYPTION_KEY=op://Nova Homelab/Authelia/storage-encryption-key
AUTHELIA_NOTIFIER_SMTP_HOST=op://Nova Homelab/SMTP/host
AUTHELIA_NOTIFIER_SMTP_USERNAME=op://Nova Homelab/SMTP/username
AUTHELIA_NOTIFIER_SMTP_PASSWORD=op://Nova Homelab/SMTP/password

#################################################
# Arcane - Container Management
# 1P Item: Arcane
#################################################
ARCANE_ENCRYPTION_KEY=op://Nova Homelab/Arcane/encryption-key
ARCANE_JWT_SECRET=op://Nova Homelab/Arcane/jwt-secret

#################################################
# Traefik / DuckDNS
# 1P Item: DuckDNS
#################################################
NOVA_DOMAIN=firefly-koonan.duckdns.org
DUCKDNS_TOKEN=op://Nova Homelab/DuckDNS/token
DUCKDNS_SUBDOMAIN=op://Nova Homelab/DuckDNS/subdomain

#################################################
# Let's Encrypt
# 1P Item: Let's Encrypt
#################################################
ACME_EMAIL=op://Nova Homelab/Let's Encrypt/email

#################################################
# Discord Notifications (WUD)
# 1P Item: Discord
#################################################
DISCORD_WEBHOOK_URL=op://Nova Homelab/Discord/webhook-url

#################################################
# Volume Sharer - Samba (optional overrides)
#################################################
#SAMBA_UID=0
#SAMBA_GID=0

#################################################
# Immich - Photo Management
# 1P Item: Immich
#################################################
IMMICH_DB_PASSWORD=op://Nova Homelab/Immich/db-password
IMMICH_POWER_TOOLS_API_KEY=op://Nova Homelab/Immich/power-tools-api-key
UPLOAD_LOCATION=/path/to/photos
DB_DATA_LOCATION=/path/to/immich-db
DB_USERNAME=postgres
DB_DATABASE_NAME=immich

#################################################
# Media - Sonarr / Radarr
# 1P Items: Sonarr, Radarr
#################################################
SONARR_API_KEY=op://Nova Homelab/Sonarr/api-key
RADARR_API_KEY=op://Nova Homelab/Radarr/api-key
SONARR_ROOT_FOLDER=/plex_tv_1
RADARR_ROOT_FOLDER=/plex_movies_1
RADARR_QUALITY_PROFILE=HD-1080p
SONARR_QUALITY_PROFILE=HD-1080p

#################################################
# Plex - Media Server
# 1P Item: Plex
#################################################
# NOTE: PLEX_CLAIM_TOKEN expires after 4 minutes.
# Get a fresh one at https://www.plex.tv/claim/ right before first deploy.
# After Plex is linked, this value is unused — set to any non-empty string.
PLEX_CLAIM_TOKEN=op://Nova Homelab/Plex/claim-token
PLEX_TOKEN=op://Nova Homelab/Plex/token
NOVA_HOST_IP=192.168.1.x
PLEX_LAN_NETWORK=192.168.1.0/24

#################################################
# Kometa - Plex Collection Manager
# 1P Items: TMDB, MDbList
#################################################
TMDB_API_KEY=op://Nova Homelab/TMDB/api-key
MDBLIST_API_KEY=op://Nova Homelab/MDbList/api-key
# KOMETA_TIME=05:00

#################################################
# Homescreen Hero
# 1P Items: Tautulli, Seerr, Homescreen Hero
#################################################
TAUTULLI_API_KEY=op://Nova Homelab/Tautulli/api-key
SEERR_API_KEY=op://Nova Homelab/Seerr/api-key
HSH_AUTH_PASSWORD=op://Nova Homelab/Homescreen Hero/auth-password
HSH_AUTH_SECRET_KEY=op://Nova Homelab/Homescreen Hero/secret-key

#################################################
# Gluetun - Mullvad WireGuard VPN
# 1P Item: Mullvad
#################################################
MULLVAD_WIREGUARD_PRIVATE_KEY=op://Nova Homelab/Mullvad/wireguard-private-key
MULLVAD_WIREGUARD_ADDRESSES=op://Nova Homelab/Mullvad/wireguard-addresses
# MULLVAD_SERVER_COUNTRY=Sweden
# MULLVAD_WIREGUARD_PORT_FORWARD=

#################################################
# qBittorrent
# 1P Item: qBittorrent
#################################################
QBITTORRENT_USER=admin
QBITTORRENT_PASS=op://Nova Homelab/qBittorrent/password

#################################################
# Z-Wave JS UI
# 1P Item: Z-Wave JS UI
#################################################
ZWAVE_SESSION_SECRET=op://Nova Homelab/Z-Wave JS UI/session-secret

#################################################
# Vibe Kanban / Dev
# 1P Item: GitHub, Vibe Kanban
#################################################
GH_TOKEN=op://Nova Homelab/GitHub/token
VIBE_KANBAN_API_KEY=op://Nova Homelab/Vibe Kanban/api-key
VIBE_KANBAN_TOOLS_SUBMIT_TOKEN=op://Nova Homelab/Vibe Kanban/tools-submit-token

#################################################
# Vikunja - Task Management
# 1P Item: Vikunja
#################################################
VIKUNJA_TOKEN=op://Nova Homelab/Vikunja/jwt-secret

#################################################
# ntfy - Push Notifications
#################################################
NTFY_TOPIC=nova-compose

#################################################
# MovieNight
# 1P Item: MovieNight
#################################################
MOVIENIGHT_DB_PASSWORD=op://Nova Homelab/MovieNight/db-password
MOVIENIGHT_TEST_DB_PASSWORD=op://Nova Homelab/MovieNight/test-db-password

#################################################
# Internal Webhook Server (optional)
# 1P Item: Internal Webhook
#################################################
# INTERNAL_WEBHOOK_SECRET=op://Nova Homelab/Internal Webhook/secret
