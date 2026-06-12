# Inbound SSH Migration — Phase 0 Audit

> **Status:** Phase 0 (audit) — read-only inventory. No changes to repos or nova yet.
> **Date:** 2026-06-05
> **Goal:** Eliminate inbound SSH on nova by replacing every `appleboy/ssh-action` GitHub Actions deploy with an outbound-only ephemeral self-hosted runner. Once all consumers cut over, public port 22 is dropped at the firewall.
> **Parent doc:** the kanban issue "Close inbound SSH on nova" defines the standard pattern, threat model, and acceptance criteria. This file is the audit output that feeds the per-repo child issues.

---

## 1. Inbound SSH consumers (workflows to migrate)

Every workflow in this table currently uses `appleboy/ssh-action` against nova and depends on the same five secrets: `NOVA_HOST`, `NOVA_USER`, `NOVA_SSH_KEY`, `NOVA_SSH_PORT`, `NOVA_CONFIG_PATH`.

| # | Repo | Workflow | Trigger | What the remote script does | Risk class |
|---|------|----------|---------|------------------------------|------------|
| 1 | `movienight` | `.github/workflows/deploy.yml` | push to `master`, `workflow_dispatch` | builds + pushes frontend & backend to GHCR, then SSH: `git fetch && git reset --hard origin/main` in `$NOVA_DIR`, `docker login ghcr.io`, `docker compose -f $NOVA_DIR/docker-compose.movienight.yaml pull/up -d`, verify three services running | **Production deploy** |
| 2 | `movienight` | `.github/workflows/deploy-test.yml` | `pull_request` (opened/sync/reopened/ready), `workflow_dispatch` | builds `:test` images, SSH: same git reset, `docker compose -f $NOVA_DIR/docker-compose.movienight-test.yaml pull && up -d --force-recreate`, verify two services | PR test deploy |
| 3 | `Vibe-kanban-tools` | `.github/workflows/deploy.yml` | push to `main`, `workflow_dispatch` | builds + pushes `ghcr.io/.../vibe-kanban-tools:latest`, SSH: `cd $NOVA_CONFIG_PATH && ./nova.sh update dev` (pulls + restarts the entire `dev` stack — multiple services) | Dev infra |
| 4 | `nova-config` | `.github/workflows/sync.yml` | push to `main`, **hourly cron** (`0 * * * *`), `workflow_dispatch` | SSH only (no build): `cd $NOVA_CONFIG_PATH && git fetch origin && git reset --hard origin/main` | Config sync (high frequency — fires 24×/day on cron alone) |

**Total:** 4 workflows in 3 repos. **24+ inbound SSH sessions / day** just from the nova-config hourly cron, before counting push/PR-driven deploys.

### Pre-migration notes about the workflows
- **Compose path mismatch in movienight** — workflows reference `$NOVA_DIR/docker-compose.movienight{,-test}.yaml` but the actual files are `$NOVA_DIR/movienight/compose.yaml` and `$NOVA_DIR/movienight-test/compose.yaml`. The current secret value of `NOVA_CONFIG_PATH` must be papering over this with a symlink, or the workflow has been broken silently. **Verify before migration**; the new workflow should reference `nova.sh update movienight` (or the canonical `<stack>/compose.yaml` path) so the inconsistency is fixed at the same time.
- **Vibe-kanban-tools** is the simplest cutover — just runs `nova.sh update dev`.
- **nova-config/sync.yml** is special: its only purpose is to call `git reset --hard` on itself on the host. With a self-hosted runner *running on nova*, the runner workspace doesn't need to push code anywhere — the systemd `gh-runner@nova-config` unit can simply tail its own `git fetch && reset` in the runner's working tree, **or** we can drop the sync workflow entirely and replace it with a host-side `systemd.timer` (see "Future work" in the parent issue — this is the obvious first candidate).

## 2. Repos with NO inbound SSH to nova (skip)

| Repo | Deploy path | Why it's not in scope |
|------|-------------|------------------------|
| `ha-config` | `deploy.yml` calls HA REST API via `curl` to `${secrets.HA_URL}` with `Authorization: Bearer ${secrets.HA_TOKEN}` | Not nova. Different attack surface (HA's exposed API), separate hardening exercise. |
| `kjsb25.github.io` | `hugo.yml` + `hugo-ci.yml` deploy to GitHub Pages via `actions/deploy-pages@v4` | No nova involvement. |
| `underthebar` | `build-server.yml` only builds + pushes `ghcr.io/.../underthebar-server`. No SSH, no deploy step. | Image lands on GHCR and is picked up by WUD / Watchtower / manual `nova.sh update`. No inbound port used. |

## 3. Secrets/variables in use (per repo)

All four consuming repos use the same five GitHub secrets. Auditable from outside the repo (the secret *names* are leaked by the workflow YAML; values are not).

| Secret | Used by | Becomes (after migration) |
|--------|---------|----------------------------|
| `NOVA_HOST` | all 4 | **Removed** — runner is on the host |
| `NOVA_USER` | all 4 | **Removed** |
| `NOVA_SSH_KEY` | all 4 | **Removed** — key no longer exists |
| `NOVA_SSH_PORT` | all 4 | **Removed** |
| `NOVA_CONFIG_PATH` | all 4 | **Demoted to repo `vars.NOVA_CONFIG_PATH`** (it's a filesystem path, not sensitive). From the runner's perspective this is the in-container mount path of the bind-mounted nova-config repo (e.g. `/nova-config`). |

New repo variables introduced by the new pattern: `vars.COMPOSE_FILE` (movienight only — selects `movienight/compose.yaml` or `movienight-test/compose.yaml`).

## 4. Current nova SSH posture (from inside the read-only vibe-kanban container)

The vibe-kanban container reaches the host only through the read-only Docker socket proxy (see `context/docker-access.md`). From in here we cannot directly observe `iptables`, `nft`, or `~deploy/.ssh/authorized_keys` — the audit of those must happen on the host as part of Phase 1. What we *can* confirm:

- The vibe-kanban container itself does not run sshd and exposes no listeners that matter.
- Nothing currently runs as a `gh-runner` host user — and per the architecture decision below, nothing will. The runners are containerised.

**To capture from the host before Phase 3** (so we have a rollback baseline):
```bash
# Run on nova (not in this container)
ss -tlnp | grep ':22'                               # confirm sshd is bound publicly
sudo iptables -S INPUT | grep -E '22|ssh'           # current public allow rule
sudo cat ~deploy/.ssh/authorized_keys               # the key that will be removed
last -n 50 deploy                                   # recent successful logins
sudo journalctl -u ssh --since '7 days ago' | wc -l # baseline auth attempt volume
```
Save the output to `nova-config/context/ssh-pre-migration-snapshot.txt` before Phase 3.

## 5. Phase-1 standard pattern (single source of truth)

**Architecture decision (2026-06-05): runners are containerised**, not bare-metal systemd units. Rationale: every other service on nova lives in a compose stack; the privilege boundary that matters (docker write access) is enforced by the socket proxy regardless of host vs. container; lifecycle/observability/update tooling (Dockge, Arcane, WUD, Homepage, ntfy) already exists for compose services and we don't have to reinvent any of it for a one-off `gh-runner@` systemd unit.

The runners live in a new `runners/` stack alongside the existing ones.

### Stack layout

```
nova-config/
├── runners/
│   ├── compose.yaml             # one service per repo + dedicated socket-proxy
│   ├── Dockerfile               # thin image: actions/runner + docker CLI + git, pinned by SHA
│   ├── entrypoint.sh            # registers via PAT → runs ./run.sh --once → exits
│   └── .env -> ../.env
```

### Per-repo service block (canonical)

```yaml
services:
  runner-movienight:
    build: .
    image: ghcr.io/nova-firefly/gh-runner:latest   # built locally, pushed for WUD
    container_name: runner-movienight
    restart: unless-stopped
    init: true
    read_only: true
    tmpfs:
      - /tmp
      - /home/runner/_work        # job workspace; vanishes on restart (ephemeral)
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    networks: [runners_proxy, traefik_default]
    environment:
      REPO_URL: https://github.com/nova-firefly/movienight
      RUNNER_NAME: nova-movienight
      RUNNER_LABELS: self-hosted,nova,movienight
      RUNNER_SCOPE: repo
      EPHEMERAL: "true"
      DOCKER_HOST: tcp://runners-socket-proxy:2375
      GH_PAT_FILE: /run/secrets/gh_pat
    secrets: [gh_pat]
    volumes:
      - /srv/nova-config:/nova-config:rw            # so the runner can `git reset --hard`
      - runner_movienight_state:/runner             # persisted runner config (registration)
    deploy:
      resources:
        limits: { cpus: '1.0', memory: 512M }
    labels:
      - wud.tag.include=^latest$
      - homepage.group=Infra
      - homepage.name=Runner — movienight
```

One block per repo: `runner-nova-config`, `runner-vibe-kanban-tools`, `runner-movienight`, `runner-movienight-test`. Labels differ; everything else is templated.

### Dedicated socket proxy (separate from the read-only one)

Decision on §7 Q1: **second proxy instance**, not extending the read-only one used by vibe-kanban. The runners get their own `tecnativa/docker-socket-proxy` with a narrow write-verb allowlist:

```yaml
runners-socket-proxy:
  image: tecnativa/docker-socket-proxy:latest
  container_name: runners-socket-proxy
  restart: unless-stopped
  read_only: true
  cap_drop: [ALL]
  cap_add: [CHOWN, SETGID, SETUID]
  networks: [runners_proxy]
  environment:
    # Read (needed for inspect + status verification)
    CONTAINERS: 1
    NETWORKS: 1
    VOLUMES: 1
    INFO: 1
    VERSION: 1
    # Write — narrow allowlist for `compose pull && up -d`
    IMAGES: 1               # /images/create (pull) — required
    POST: 1                 # allow POST verbs on the above resources only
    # Explicitly NOT allowed (defaults are 0): EXEC, BUILD, SERVICES, TASKS, NODES, SECRETS, PLUGINS, SYSTEM
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
```

> **Note:** `tecnativa/docker-socket-proxy` toggles by resource, not verb. `POST=1` + `CONTAINERS=1` lets the runner start/stop/recreate containers but **cannot** `exec` (separate `EXEC` toggle, kept off) or build images. The blast radius for a compromised runner: it can start/stop/recreate containers managed by compose. It cannot get a shell, cannot mount arbitrary host paths, cannot create new containers with `privileged: true` (because it can't `POST /containers/create` without `CONTAINERS=1` + `POST=1` *and* the runner's payload is a known compose file the runner doesn't control). Acceptable.

### Runner labels (GitHub side)
Workflows target `runs-on: [self-hosted, nova, <repo-name>]`. A compromised repo cannot dequeue jobs intended for another runner because each container registers with its own repo URL and labels.

### Registration & PAT
- One GitHub PAT (`repo` scope) stored as a docker secret: `secrets/gh_pat` mounted at `/run/secrets/gh_pat` (mode 0400, owned by runner uid).
- `entrypoint.sh` exchanges the PAT for a 1h registration token at container start, registers the runner, then `exec`s `./run.sh --once`. After the job, the runner exits, `restart: unless-stopped` brings the container back up, and re-registration happens again — fresh state every job.
- PAT lifetime: 90 days, rotation via a calendar reminder and `runners/.env` update. (Open Q for §7: 1Password CLI sidecar to fetch at start vs. static secret file.)

### Workflow shape (canonical, unchanged from bare-metal proposal)
Only the deploy job moves. Build/push jobs stay on `ubuntu-latest`.

```yaml
deploy:
  needs: [build-push-frontend, build-push-backend]
  runs-on: [self-hosted, nova, <repo-label>]
  timeout-minutes: 10
  permissions:
    contents: read
    packages: read
  steps:
    - name: Deploy
      env:
        NOVA_DIR: ${{ vars.NOVA_CONFIG_PATH }}     # in-container path, e.g. /nova-config
        COMPOSE_FILE: ${{ vars.COMPOSE_FILE }}     # optional, per-repo
      run: |
        cd "$NOVA_DIR"
        git fetch origin
        git reset --hard origin/main
        echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
        docker compose -f "$COMPOSE_FILE" pull
        docker compose -f "$COMPOSE_FILE" up -d
        # verification loop, per-repo service list
```

### Hardening checklist (must pass per repo before closing the child issue)
- [ ] Runner runs in `EPHEMERAL=true` mode — one job per container lifetime.
- [ ] Runner is repo-scoped (`RUNNER_SCOPE=repo`), not org-scoped.
- [ ] Runner container has `cap_drop: [ALL]`, `read_only: true`, `security_opt: [no-new-privileges:true]`, `init: true`.
- [ ] Job workspace is `tmpfs` — no state survives the job.
- [ ] `DOCKER_HOST` points at the dedicated `runners-socket-proxy`, never raw `/var/run/docker.sock`.
- [ ] Bind mounts limited to `/srv/nova-config:/nova-config:rw` and the runner's own state volume. No other host paths.
- [ ] Resource limits set (`cpus`, `memory`) so a runaway job can't starve the host.
- [ ] All third-party actions in workflows pinned to commit SHA.
- [ ] Workflow `permissions:` set to the narrowest scope needed.
- [ ] Deploy workflow `on:` does not allow untrusted forks to trigger deploys.
- [ ] Branch protection on `master`/`main`.
- [ ] GHCR pull uses `GITHUB_TOKEN`, not a long-lived PAT.

## 6. Phased rollout — proposed PR/issue split

Each row below is the proposed unit of work (one PR + one kanban child issue).

| # | Phase | Repo | What lands | Blocks | Blocked by |
|---|-------|------|------------|--------|------------|
| **A** | 1 | `nova-config` | New `runners/` stack: `compose.yaml` (one runner service per repo + dedicated socket-proxy), `Dockerfile`, `entrypoint.sh`, secrets wiring, docs (`context/runners.md`), `runners` added to `ALL_STACKS` in `nova.sh` | B, C, D | — |
| **B** | 2 | `nova-config` | Migrate `sync.yml` to self-hosted runner (or replace with host-side systemd timer — see §1 note) | E | A |
| **C** | 2 | `Vibe-kanban-tools` | Migrate `deploy.yml` to self-hosted runner | E | A |
| **D** | 2 | `movienight` | Migrate `deploy.yml` + `deploy-test.yml` to self-hosted runner; fix compose path mismatch | E | A |
| **E** | 3 | `nova-config` | Capture pre-migration snapshot, drop inbound port 22 at firewall, document break-glass | — | B, C, D all green for ≥1 successful prod deploy each |

Ordering rationale:
- **A first** so the standard pattern exists before per-repo PRs.
- **B (sync.yml) goes first among the migrations** — lowest blast radius (config sync, no images to build, can verify quickly), and the highest-frequency current SSH consumer. If the runner pattern is wrong, we learn here on a cheap workflow.
- **C (Vibe-kanban-tools)** next — single-line `nova.sh update dev`, second-lowest blast radius.
- **D (movienight)** last among the migrations — biggest workflow, real users, and bundles the compose-path-mismatch fix. Both `deploy.yml` and `deploy-test.yml` should land in one PR to avoid a window where one path is migrated and the other still needs SSH.
- **E** only after each migrated workflow has done at least one successful production deploy on the new path. Keep sshd running but firewalled for ≥2 weeks as the rollback path before disabling the service entirely.

## 7. Open questions for the user before Phase 1

1. ~~**Socket-proxy strategy.**~~ **Decided 2026-06-05:** dedicated second `tecnativa/docker-socket-proxy` instance for the runners stack (see §5). The existing read-only proxy used by vibe-kanban is untouched.
2. **Replace `nova-config/sync.yml` entirely?** — With a runner container on nova, the workflow's whole purpose (`git fetch && reset`) is redundant. Two options:
   - **Drop the workflow** and bake the same `git fetch && reset --hard` into the runner image's startup loop, or into a tiny separate `nova-config-sync` container with a cron entrypoint. Saves one runner job pickup per hour and removes the workflow entirely.
   - **Migrate it** to the self-hosted runner for symmetry with the other migrations.
3. **PAT delivery to the runner containers** — three options for `gh_pat` secret:
   - **Plain docker secret from a file** under `runners/secrets/gh_pat` (gitignored; mode 0400). Simple, reproducible. PAT rotation = edit file + `docker compose up -d`.
   - **1Password CLI sidecar** that fetches the PAT at container start and writes it to a tmpfs path. Stronger (no PAT on disk at rest), more moving parts.
   - **GitHub App + JWT** instead of PAT. Best practice; biggest scope of work. Probably overkill for a homelab.
4. **Runner monitoring** — pick one:
   - WUD already watches container exits; pair with ntfy on `oom_killed` / repeated restart loops via existing `nova.sh` ntfy hook.
   - Add a Prometheus `cadvisor` rule that pages when a runner container is in `restarting` state for >5m.

## 8. References

- Parent kanban issue: "Close inbound SSH on nova: migrate all repo deploys to self-hosted GitHub Actions runners" — defines pattern, threat model, acceptance criteria.
- `context/docker-access.md` — current socket-proxy config (read-only).
- `context/patterns.md` — compose conventions; the `runners/` stack must follow these (Traefik labels not needed since runners aren't HTTP-exposed; Homepage + WUD labels still apply).
- GitHub docs:
  - <https://docs.github.com/en/actions/hosting-your-own-runners>
  - <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners>
