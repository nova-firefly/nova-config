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
| `NOVA_CONFIG_PATH` | all 4 | **Demoted to repo `vars.NOVA_CONFIG_PATH`** (it's a filesystem path, not sensitive). For nova-config it can be hard-coded in the systemd unit's `WorkingDirectory`. |

New repo variables introduced by the new pattern: `vars.COMPOSE_FILE` (movienight only — selects `movienight/compose.yaml` or `movienight-test/compose.yaml`).

## 4. Current nova SSH posture (from inside the read-only vibe-kanban container)

The vibe-kanban container reaches the host only through the read-only Docker socket proxy (see `context/docker-access.md`). From in here we cannot directly observe `iptables`, `nft`, or `~deploy/.ssh/authorized_keys` — the audit of those must happen on the host as part of Phase 1. What we *can* confirm:

- The vibe-kanban container itself does not run sshd and exposes no listeners that matter.
- No `gh-runner` user exists in this container's namespace (it shouldn't — runner is for the host).
- `getent passwd gh-runner` → not present, confirming we're starting from a clean slate for Phase 1.

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

Lifted from the parent issue and consolidated here so per-repo migrations don't drift:

### Runner host layout
- One `gh-runner` system user: `useradd -r -m -d /srv/gh-runner -s /usr/sbin/nologin gh-runner`
- Per-repo tree: `/srv/gh-runner/<repo>/{runner,_work}`
- Group: `gh-runner` is a member of the docker-socket-proxy access group, **not** the raw `docker` group, **not** sudoers.
- systemd unit template: `nova-config/systemd/gh-runner@.service` — `User=gh-runner`, `Restart=always`, runs `./run.sh --once` so each job is a fresh ephemeral process. Hardening: `ProtectSystem=strict`, `ProtectHome=true`, `NoNewPrivileges=true`, `PrivateTmp=true`, `ReadWritePaths=/srv/gh-runner/<repo>` plus whichever compose-data paths the deploy touches. Bounded by `MemoryMax`, `TasksMax`, `CPUQuota`.

### Runner labels
Workflows target `runs-on: [self-hosted, nova, <repo-name>]`. A compromised repo cannot dequeue jobs intended for another runner.

### Registration tokens
GitHub registration tokens TTL is 1h. Generated at install time only, stored at `/etc/gh-runner/<repo>.token` (mode 600, root-owned). The install script in `nova-config/scripts/install-gh-runner.sh` will own this rotation.

### Workflow shape (canonical)
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
        NOVA_DIR: ${{ vars.NOVA_CONFIG_PATH }}
        COMPOSE_FILE: ${{ vars.COMPOSE_FILE }}    # optional, per-repo
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
- [ ] Runner is `--ephemeral`.
- [ ] Runner is repo-scoped, not org-scoped.
- [ ] Runner user has no sudo and no login shell.
- [ ] Runner uses the socket proxy, not `/var/run/docker.sock` directly. **Note:** the current proxy is read-only — Phase 1 must either (a) extend `socket-proxy` env with the narrowest possible write verb allowlist for compose-restart, or (b) deploy a second proxy instance dedicated to `gh-runner`. **Decision needed** before Phase 1 PR.
- [ ] systemd unit has `ProtectSystem=strict`, `NoNewPrivileges=true`, `PrivateTmp=true`, scoped `ReadWritePaths`.
- [ ] All third-party actions pinned to commit SHA.
- [ ] Workflow `permissions:` set to the narrowest scope needed.
- [ ] Deploy workflow `on:` does not allow untrusted forks to trigger deploys.
- [ ] Branch protection on `master`/`main`.
- [ ] GHCR pull uses `GITHUB_TOKEN`, not a long-lived PAT.

## 6. Phased rollout — proposed PR/issue split

Each row below is the proposed unit of work (one PR + one kanban child issue).

| # | Phase | Repo | What lands | Blocks | Blocked by |
|---|-------|------|------------|--------|------------|
| **A** | 1 | `nova-config` | Install script (`scripts/install-gh-runner.sh`), systemd template (`systemd/gh-runner@.service`), docs (`context/gh-runner.md`), socket-proxy write-verb decision + config | B, C, D | — |
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

1. **Socket-proxy strategy** — extend the existing read-only proxy with a narrow write verb allowlist for `gh-runner`, or run a second dedicated proxy instance? Second instance is cleaner from a blast-radius standpoint and avoids weakening the read-only guarantee currently relied on by vibe-kanban.
2. **Replace `nova-config/sync.yml` entirely?** — With the runner on nova, the workflow's whole purpose (`git fetch && reset`) becomes redundant: a systemd timer on the host does the same thing without ever talking to GitHub Actions. Drop the workflow, or migrate it as-is for symmetry?
3. **GitHub PAT for registration-token generation** — needs `repo` scope and lives on the host. Where stored (1Password CLI lookup at install time, vs. plaintext in `/etc/gh-runner/`)? PAT TTL?
4. **Runner host monitoring** — add `node_exporter` textfile collector + Prometheus alert for `gh-runner@*.service` in `failed` state >5m, or rely on ntfy from a wrapper script? (nova already publishes ntfy from `nova.sh` — same channel makes sense.)

## 8. References

- Parent kanban issue: "Close inbound SSH on nova: migrate all repo deploys to self-hosted GitHub Actions runners" — defines pattern, threat model, acceptance criteria.
- `context/docker-access.md` — current socket-proxy config (read-only).
- `context/patterns.md` — compose conventions; new compose-data `ReadWritePaths` for the systemd unit must follow these.
- GitHub docs:
  - <https://docs.github.com/en/actions/hosting-your-own-runners>
  - <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners>
