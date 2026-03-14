# Conventions & Patterns

Reference for consistent patterns when editing compose files or adding new services.

## Service Block Template

```yaml
  my-service:
    container_name: "my-service"
    image: "some/image:tag"
    environment:
      - "TZ=${TZ}"
      - "PUID=${PUID}"
      - "PGID=${PGID}"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:PORT/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      # Traefik
      traefik.enable: "true"
      traefik.http.routers.my-service.rule: "Host(`my-service.${NOVA_DOMAIN}`)"
      traefik.http.routers.my-service.entrypoints: "websecure"
      traefik.http.routers.my-service.tls: "true"
      traefik.http.services.my-service.loadbalancer.server.port: "PORT"
      # Homepage
      homepage.group: "Tools"           # Infrastructure | Media | Downloads | Tools | Development | Home Automation
      homepage.name: "My Service"
      homepage.icon: "my-service.svg"   # or .png; see gethomepage.dev/icons
      homepage.href: "https://my-service.${NOVA_DOMAIN}"
      homepage.description: "Short description"
      # WUD
      wud.watch: "true"
      wud.watch.digest: "true"          # omit for versioned tags (e.g. postgres:15)
      wud.trigger.include: "dockercompose.STACKNAME,discord.notify"
    networks:
      - "traefik_default"
    ports:
      - "HOST_PORT:CONTAINER_PORT/tcp"
    restart: "unless-stopped"
    volumes:
      - "my_service_config:/config"
```

## Label Conventions

### Traefik Labels
- Router name matches service name (e.g. `traefik.http.routers.radarr.*`)
- Always set `entrypoints: websecure` and `tls: true`
- Only add `tls.certresolver: letsencrypt` when the service needs its own cert (usually not needed — wildcard cert handles subdomains)
- For services with multiple routes (e.g. movienight API vs frontend), use distinct router names

### Homepage Labels
- `homepage.group` must match a group defined in `homepage/settings.yaml`
- Icon format: `name.svg` or `name.png` (see https://gethomepage.dev/latest/configs/services/#icons)
- Emoji icons: `emoji-🍿` format (used for movienight)
- `homepage.href` should use `https://` for externally-facing URLs

### WUD Labels
- `wud.watch: "true"` — enable update watching
- `wud.watch.digest: "true"` — add for floating tags like `latest` (detects digest changes)
- `wud.watch: "false"` — explicitly disable (e.g. wud itself, volume-sharer)
- `wud.trigger.include` — comma-separated list of triggers:
  - `dockercompose.STACKNAME` — auto-update via compose pull+up
  - `discord.notify` — send Discord notification
  - Some services only get `discord.notify` (no auto-update) e.g. plex, traefik

## Security Hardening (cap_drop)

Applied to most media/arr services. Standard list:

```yaml
    cap_drop:
      - "AUDIT_CONTROL"
      - "BLOCK_SUSPEND"
      - "DAC_READ_SEARCH"
      - "IPC_LOCK"
      - "IPC_OWNER"
      - "LEASE"
      - "LINUX_IMMUTABLE"
      - "MAC_ADMIN"
      - "MAC_OVERRIDE"
      - "NET_ADMIN"
      - "NET_BROADCAST"
      - "SYSLOG"
      - "SYS_ADMIN"
      - "SYS_BOOT"
      - "SYS_MODULE"
      - "SYS_NICE"
      - "SYS_PACCT"
      - "SYS_PTRACE"
      - "SYS_RAWIO"
      - "SYS_RESOURCE"
      - "SYS_TIME"
      - "SYS_TTY_CONFIG"
      - "WAKE_ALARM"
```

Note: `cap_drop` uses names without `CAP_` prefix (sonarr mistakenly uses the prefix — both work).
Do not apply to services that need privileges: traefik, gluetun (needs NET_ADMIN), glances (needs host pid/network), arcane.

## Volume Patterns

### External volumes (pre-created, persistent across recreates)
```yaml
    volumes:
      - "service_config:/config"

volumes:
  service_config:
    external: true
```
Create before first `up`: `docker volume create service_config`

### Bind mounts (host path directly)
```yaml
    volumes:
      - "/data1/some/path:/container/path"
      - "./relative/path:/container/path"   # relative to compose file location
```

### Read-only mounts
```yaml
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
```

## Network Patterns

### Standard internet-facing service
```yaml
    networks:
      - "traefik_default"

networks:
  traefik_default:
    external: true
    name: "traefik_default"
```

### Internal-only network (DB isolation)
```yaml
networks:
  mystack_internal:
    internal: true
```

### Host network mode
```yaml
    network_mode: "host"
```
Services in host mode cannot use Traefik Docker labels — add routes to `traefik/dynamic.yaml` instead.

### Sidecar network (transmission inside gluetun)
```yaml
    network_mode: "service:gluetun"
```
The sidecar inherits the gateway service's network namespace. Put Traefik labels on the gateway service, not the sidecar.

## Stack File Header

Each compose file begins with a comment block:
```yaml
# Stack Name Stack - Brief description
# Usage: docker compose -f docker-compose.STACK.yaml up -d
# Requires .env file for: VAR1, VAR2
```

## Environment Variable Conventions

- All secrets in `.env` (never inline in compose files)
- Reference as `${VAR_NAME}` in compose YAML
- Document in `.env.example` with:
  - Section header comment with stack name
  - Inline comment explaining purpose and how to generate
- Shared vars (`TZ`, `PUID`, `PGID`, `NOVA_HOSTNAME`, `NOVA_DOMAIN`) available to all stacks

## Healthcheck Patterns

### HTTP endpoint
```yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:PORT/path >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
```

### PostgreSQL
```yaml
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U USERNAME -d DBNAME"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### Disable healthcheck
```yaml
    healthcheck:
      disable: true
```

## Submodule Stack Pattern

When a stack has its own git submodule (e.g. `movienight/`), nova uses a base + override approach:

```
docker compose -f <stack>/docker-compose.yml \   # upstream (owned by the submodule)
               -f docker-compose.<stack>.yaml \   # nova override (owned by nova-config)
               --profile <profile> <cmd>
```

**How it works:**
- `nova.sh` auto-detects the submodule by checking whether `<stack>/docker-compose.yml` (or `.yaml`) exists
- The upstream file defines services, images, volumes, and healthchecks
- The nova override file adds only what nova owns: Traefik/Homepage/WUD labels, nova networks, and any nova-managed services absent from the upstream production profile
- Per-stack `STACK_PROFILES[<stack>]` in nova.sh activates the right upstream profile (e.g. `production`)
- Docker Compose deep-merges the files: scalar fields (image, restart) are replaced; mappings (labels, environment) are merged; sequences (ports, volumes) are **appended by default**
- Use `!reset` YAML tag to **replace** (not append) an inherited sequence. E.g. to clear upstream port bindings so only Traefik routes traffic: `ports: !reset []`
- **All paths** (including those in the nova override file) are resolved relative to the **first** `-f` file's directory (the submodule root). E.g. if the submodule is at `movienight/`, a build context of `./backend` in the override resolves to `movienight/backend/` ✓ — not `./movienight/backend` which would double-up to `movienight/movienight/backend` ✗

**Adding a new submodule stack:**
1. Initialize the submodule: `git submodule add <repo> <stack>`
2. Create `docker-compose.<stack>.yaml` with only nova overrides (labels, networks, nova-managed services)
3. Add the stack name to `ALL_STACKS` in nova.sh
4. If the upstream compose uses profiles, add `STACK_PROFILES[<stack>]="<profile>"` in nova.sh
5. Add WUD trigger env vars to `docker-compose.infra.yaml`
6. Update `context/stacks.md`

## Adding a New Stack

1. Create `docker-compose.<name>.yaml` with the header comment block
2. Add `<name>` to `ALL_STACKS` array in `nova.sh` line 27
3. Add WUD trigger env vars to the `wud` service in `docker-compose.infra.yaml`:
   ```yaml
   - "WUD_TRIGGER_DOCKERCOMPOSE_NAME_FILE=/compose/docker-compose.name.yaml"
   - "WUD_TRIGGER_DOCKERCOMPOSE_NAME_BACKUP=true"
   - "WUD_TRIGGER_DOCKERCOMPOSE_NAME_PRUNE=true"
   ```
4. Add env vars to `.env.example` with `# Stack: name` annotation
5. Update `context/stacks.md`

## Adding a Host-Mode Service to Traefik

Edit `traefik/dynamic.yaml`:
```yaml
http:
  routers:
    myservice:
      rule: Host(`myservice.{{ env "NOVA_DOMAIN" }}`)
      entrypoints:
        - websecure
      tls: {}
      service: myservice
  services:
    myservice:
      loadBalancer:
        servers:
          - url: http://host.docker.internal:PORT
        passHostHeader: true
```
