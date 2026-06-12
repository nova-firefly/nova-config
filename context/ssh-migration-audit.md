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

**Architecture decision (2026-06-05): runners are containerised**, not bare-metal systemd units. Rationale: every other service on nova lives in a compose stack; the privilege boundary that matters (docker write access) is enforced by the socket proxy regardless of host vs. container; lifecycle/observability/update tooling (Dockge, Arcane, WUD, Homepage, ntfy) already exists for compose services and we don't have to reinvent any of it.

**Simplifications adopted (2026-06-05, second pass):**
1. **Runners live in `infra/`**, not a new `runners/` stack. Runners are infra. One fewer stack, one fewer `.env` symlink.
2. **Use the upstream `myoung34/github-runner` image** pinned by digest. No custom `Dockerfile`, no `entrypoint.sh`, no GHCR build/push pipeline of our own.
3. **`nova-config/sync.yml` is deleted, not migrated.** A small `nova-config-sync` sidecar in `infra/` does the `git fetch && reset --hard origin/main` on a cron. Push-triggered sync is dropped (reconciliation latency ≤ cron interval, which is acceptable).
4. **The nova-config bind mount is read-only in every runner.** The `nova-config-sync` sidecar is the sole writer. A compromised runner cannot taint the source of truth that other runners read.
5. **One runner per repo**, not per environment. Movienight prod + PR-test share `runner-movienight` (it just registers both labels on the same repo).

### Stack layout (additions to `infra/compose.yaml`)

```
nova-config/infra/compose.yaml
  ├── (existing) socket-proxy        # read-only, untouched
  ├── (new) runners-socket-proxy     # write-allowlist for runners only
  ├── (new) nova-config-sync         # cron sidecar, sole writer to /srv/nova-config
  ├── (new) runner-nova-config       # registers as [self-hosted, nova, nova-config]
  ├── (new) runner-vibe-kanban-tools # registers as [self-hosted, nova, vibe-kanban-tools]
  └── (new) runner-movienight        # registers as [self-hosted, nova, movienight, movienight-test]
```

Three runner containers (down from four). The `runners/` directory is not created.

### Per-repo runner service block (canonical)

```yaml
services:
  runner-movienight:
    image: myoung34/github-runner@sha256:<pinned>   # pinned digest, WUD watches for new digests
    container_name: runner-movienight
    restart: unless-stopped
    init: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs:
      - /tmp
      - /_work                          # job workspace; vanishes between jobs
    networks: [runners_proxy]
    environment:
      REPO_URL: https://github.com/nova-firefly/movienight
      RUNNER_NAME: nova-movienight
      RUNNER_SCOPE: repo
      LABELS: nova,movienight,movienight-test     # one runner, both env labels
      EPHEMERAL: "true"
      DISABLE_AUTO_UPDATE: "true"        # we pin image digest, don't let runner self-update
      DOCKER_HOST: tcp://runners-socket-proxy:2375
      ACCESS_TOKEN: ${GH_PAT}            # from root .env, same source of truth as every other secret
    volumes:
      - /srv/nova-config:/nova-config:ro          # READ-ONLY — sync sidecar owns writes
      - runner_movienight_state:/runner            # registration state across restarts
    deploy:
      resources:
        limits: { cpus: '1.0', memory: 512M }
    labels:
      - wud.tag.include=^[0-9a-f]{64}$            # WUD tracks digest
      - homepage.group=Infra
      - homepage.name=Runner — movienight
```

`runner-nova-config` and `runner-vibe-kanban-tools` differ only in `REPO_URL`, `RUNNER_NAME`, `LABELS`, and the state volume name.

### nova-config sync sidecar (replaces `sync.yml`)

```yaml
nova-config-sync:
  image: alpine/git:latest                # pinned to a digest in the real PR
  container_name: nova-config-sync
  restart: unless-stopped
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
  volumes:
    - /srv/nova-config:/repo:rw           # the only writer to this path
  entrypoint: ["/bin/sh", "-c"]
  command:
    - |
      while true; do
        cd /repo && git fetch origin && git reset --hard origin/main
        sleep 600     # 10 min — much faster reconciliation than the old hourly cron
      done
  labels:
    - homepage.group=Infra
    - homepage.name=nova-config sync
```

Drops the `nova-config/.github/workflows/sync.yml` workflow entirely. Reconciliation window: ≤10 min vs. the old hourly cron + push trigger. No GitHub Actions round-trip; no inbound runner job per sync.

### Dedicated socket proxy for runners (separate from the read-only one)

Decision on §7 Q1: **second proxy instance**, not extending the read-only one used by vibe-kanban.

```yaml
runners-socket-proxy:
  image: tecnativa/docker-socket-proxy@sha256:<pinned>
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

> **Note:** `tecnativa/docker-socket-proxy` toggles by resource, not verb. `POST=1` + `CONTAINERS=1` lets the runner start/stop/recreate containers but **cannot** `exec` (separate `EXEC` toggle, kept off) or build images. Blast radius for a compromised runner: start/stop/recreate containers managed by compose. Cannot get a shell, cannot mount arbitrary host paths, cannot mutate `/srv/nova-config` (read-only mount).

### Runner labels (GitHub side)
Workflows target `runs-on: [self-hosted, nova, <repo-name>]`. The runner for movienight registers both `movienight` and `movienight-test` so one container handles both prod and PR-test deploys.

### Registration & PAT
- One GitHub PAT (`repo` scope) lives in the root `.env` as `GH_PAT` — same delivery mechanism as every other secret in nova. No new files, no docker secrets indirection. `.env` is already gitignored and mode 0600.
- `myoung34/github-runner`'s built-in entrypoint exchanges the PAT for a 1h registration token at container start, registers the runner, runs the job, and (with `EPHEMERAL=true`) exits. `restart: unless-stopped` brings the container back; re-registration happens again — fresh state every job. No custom entrypoint of ours.
- PAT lifetime: 90 days, rotation via calendar reminder + edit `.env` + `nova.sh up infra`.
- Add `GH_PAT=` to `.env.example` with an `# infra` annotation.

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
| **A** | 1 | `nova-config` | Add to `infra/compose.yaml`: `runners-socket-proxy`, `nova-config-sync` sidecar, three `runner-*` services (using pinned `myoung34/github-runner` digest). Add gitignored `infra/secrets/gh_pat`. **Delete `nova-config/.github/workflows/sync.yml`** in the same PR. Update `context/stacks.md` + new `context/runners.md`. | C, D | — |
| **C** | 2 | `Vibe-kanban-tools` | Migrate `deploy.yml` to self-hosted runner | E | A |
| **D** | 2 | `movienight` | Migrate `deploy.yml` + `deploy-test.yml` to self-hosted runner; fix compose path mismatch | E | A |
| **E** | 3 | `nova-config` | Capture pre-migration snapshot, drop inbound port 22 at firewall, document break-glass | — | C, D all green for ≥1 successful prod deploy each |

> **`sync.yml` is gone, not migrated.** Old phase B is folded into phase A (sidecar is part of the same PR). The hourly cron + push-triggered SSH from GitHub Actions disappears entirely.

Ordering rationale:
- **A first** so the standard pattern + sync sidecar exist before per-repo PRs.
- **C (Vibe-kanban-tools)** next — single-line `nova.sh update dev`, lowest blast radius of the remaining migrations. If the runner pattern is wrong, we learn here on a cheap workflow.
- **D (movienight)** last among the migrations — biggest workflow, real users, and bundles the compose-path-mismatch fix. Both `deploy.yml` and `deploy-test.yml` land in one PR (same runner serves both labels, no need to split).
- **E** only after each migrated workflow has done at least one successful production deploy on the new path. Keep sshd running but firewalled for ≥2 weeks as the rollback path before disabling the service entirely.

## 7. Open questions for the user before Phase 1

1. ~~**Socket-proxy strategy.**~~ **Decided 2026-06-05:** dedicated second `tecnativa/docker-socket-proxy` instance, lives in `infra/`. The existing read-only proxy used by vibe-kanban is untouched.
2. ~~**Replace `nova-config/sync.yml` entirely?**~~ **Decided 2026-06-05:** delete it. Replaced by the `nova-config-sync` sidecar in §5 (10-minute reconciliation loop). No GitHub Actions round-trip for config sync at all.
3. ~~**Custom runner image?**~~ **Decided 2026-06-05:** no — pin `myoung34/github-runner` by digest. WUD watches for new digests.
4. ~~**Per-environment vs. per-repo runners for movienight?**~~ **Decided 2026-06-05:** one runner per repo. `runner-movienight` registers both `movienight` and `movienight-test` labels.
5. ~~**PAT delivery to the runner containers.**~~ **Decided 2026-06-12:** put `GH_PAT` in the root `.env` like every other nova secret. No docker-secrets indirection, no separate file. Rotation = edit `.env` + `nova.sh up infra`.
6. ~~**Runner monitoring.**~~ **Decided 2026-06-12:** rely on Docker's `restart: unless-stopped` policy and nothing else for v1. If a runner crashes Docker brings it back; ephemeral mode means the next job picks up a clean container. No WUD/ntfy alerting plumbing for runner health in v1 — add it only if a real failure mode surfaces.

## 8. References

- Parent kanban issue: "Close inbound SSH on nova: migrate all repo deploys to self-hosted GitHub Actions runners" — defines pattern, threat model, acceptance criteria.
- `context/docker-access.md` — current socket-proxy config (read-only).
- `context/patterns.md` — compose conventions; the `runners/` stack must follow these (Traefik labels not needed since runners aren't HTTP-exposed; Homepage + WUD labels still apply).
- GitHub docs:
  - <https://docs.github.com/en/actions/hosting-your-own-runners>
  - <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners>
