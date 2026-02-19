FROM alpine:3.21

# curl: Backrest API calls + Discord webhook
# openssh-client: SSH connectivity check for SFTP host
# docker-cli: docker exec for pg_dumpall in immich_postgres container
RUN apk add --no-cache \
    curl \
    openssh-client \
    docker-cli

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
