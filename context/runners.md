# Self-hosted GitHub Actions Runners

Containerised, ephemeral, one-runner-per-repo. Lives in the `infra` stack (runners are infra).
Replaces the GitHub Actions SSH-deploy round-trip with a host-side reconciliation loop.

## Topology

```
                 +----------------+
                 | GitHub Actions |
                 +-------+--------+
                         | long-poll over HTTPS (egress only)
                         v
+----------------------------------------------------+
| infra stack (docker compose)                       |
|                                                    |
|   runner-nova-config ─┐                            |
|   runner-vibe-kanban-tools ─┼──> runners-socket-proxy ──ro──> /var/run/docker.sock
|   runner-movienight ─┘      (POST allowlist)                            |
|                                                                          |
|   nova-config-sync ───rw──> /srv/nova-config <──ro── (runners read here) |
|                       ^                                                  |
|                       | git fetch && reset --hard origin/main, every 10m |
|                       v                                                  |
|                  GitHub                                                  |
+--------------------------------------------------------------------------+
```

Key invariants:

- **`/srv/nova-config` is read-only in every runner.** `nova-config-sync` is the sole writer.
- **One runner per repo, not per environment.** `runner-movienight` registers both the
  `movienight` and `movienight-test` labels.
- **No inbound firewall rules.** All connections to GitHub are outbound long-polls.
- **`ACCESS_TOKEN` (`GH_PAT`) is the only secret.** Lives in root `.env`, same delivery as
  every other nova secret. No `infra/secrets/gh_pat` file, no docker-secrets indirection.
- **Image digests must be pinned.** The compose file ships with placeholder all-zero digests;
  Docker will refuse to pull until they are replaced (see [Pin image digests](#pin-image-digests)).

## Prerequisites

Before the first `nova.sh up infra` after these services land:

1. **Host directory** — create `/srv/nova-config` and clone the repo into it:
   ```bash
   sudo mkdir -p /srv/nova-config
   sudo chown "$(id -u):$(id -g)" /srv/nova-config
   git clone https://github.com/nova-firefly/nova-config.git /srv/nova-config
   ```
   The sync sidecar runs `git reset --hard origin/main` against this checkout every 10 min,
   so any local edits here will be destroyed — edit through PRs, not in place.

2. **GH_PAT** — fine-grained PAT scoped to all three runner repos:
   - `nova-firefly/nova-config`
   - `nova-firefly/vibe-kanban-tools`
   - `nova-firefly/movienight`

   Required permission: **Administration: read & write** (lets the runner register and
   unregister itself). Recommended extra: **Actions: read** (for log fetches). No org scope.

   Add to root `.env` as `GH_PAT=...`.

3. **Pinned digests** — replace the placeholder `sha256:000…000` digests in
   `infra/compose.yaml` with current upstream digests for `myoung34/github-runner` and
   `alpine/git`. See [Pin image digests](#pin-image-digests).

4. **Disable any per-repo branch-protection rules requiring GitHub-hosted runners.** Workflows
   targeting `[self-hosted, nova, <repo>]` will sit pending forever if the rule blocks self-hosted.

## Add a runner

Repeat the per-runner block in `infra/compose.yaml`. Five fields change per repo:

```yaml
runner-<repo>:
  container_name: "runner-<repo>"
  # …all hardening identical to siblings…
  environment:
    - "ACCESS_TOKEN=${GH_PAT}"
    - "REPO_URL=https://github.com/<owner>/<repo>"      # 1
    - "RUNNER_NAME=runner-<repo>"                       # 2
    - "LABELS=nova,<repo>"                              # 3 (add more comma-separated for multi-env)
    # …rest identical to siblings…
  volumes:
    - "/srv/nova-config:/nova-config:ro"
    - "runner_<repo>_state:/runner"                     # 4 — also add to top-level volumes:
```

Plus a `runner_<repo>_state:` entry under the top-level `volumes:` block (5).

Bring it up:

```bash
./nova.sh up infra
```

Verify in GitHub: **Settings → Actions → Runners** for the target repo. The new runner
should appear as **Idle** within ~30 s. Workflows can then target it with
`runs-on: [self-hosted, nova, <repo>]`.

## Rotate `GH_PAT`

1. Generate a new PAT with the same repo set + permissions.
2. Update `GH_PAT=…` in root `.env`.
3. Recreate the runners so they re-register with the new token:
   ```bash
   ./nova.sh recreate infra runner-nova-config
   ./nova.sh recreate infra runner-vibe-kanban-tools
   ./nova.sh recreate infra runner-movienight
   ```
4. In GitHub, delete the now-orphaned old runner entries from
   **Settings → Actions → Runners** for each repo (the ephemeral pattern means stale
   entries don't auto-clean — they appear as Offline forever otherwise).
5. Revoke the old PAT at <https://github.com/settings/tokens>.

A plain `./nova.sh restart infra` is insufficient because environment changes only take
effect on container recreation, not restart.

## Pin image digests

Required once on initial deploy and again after any intentional upstream pull.

```bash
# Pull the floating tag once on the host to learn the current digest, then
# extract just the digest:
docker pull myoung34/github-runner:latest
docker inspect --format='{{index .RepoDigests 0}}' myoung34/github-runner:latest
# Output: myoung34/github-runner@sha256:abc123…

docker pull alpine/git:latest
docker inspect --format='{{index .RepoDigests 0}}' alpine/git:latest
```

Replace every occurrence of `myoung34/github-runner@sha256:000…000` and
`alpine/git@sha256:000…000` in `infra/compose.yaml` with the printed digest.
Commit and PR — `nova-config-sync` will roll it out to `/srv/nova-config`, then
`./nova.sh recreate infra` picks up the new images.

## Troubleshooting

### Runner is stuck in a restart loop

```bash
docker logs --tail 100 runner-<repo>
```

Most common causes:

| Symptom in logs | Cause | Fix |
| --- | --- | --- |
| `Http response code: NotFound from 'POST …/registration-token'` | `REPO_URL` points to a repo the PAT cannot administer, or repo was renamed | Fix `REPO_URL`; verify PAT scope covers the repo |
| `401 Unauthorized` against api.github.com | `GH_PAT` is expired, revoked, or missing `Administration: write` | Rotate PAT (see above) |
| `manifest for myoung34/github-runner@sha256:… not found` | Placeholder digest never replaced, or replaced with a typo | Re-pin the digest |
| `Cannot connect to the Docker daemon at tcp://runners-socket-proxy:2375` | `runners-socket-proxy` is unhealthy or hasn't joined `runners_net` | `docker logs runners-socket-proxy`; recreate proxy |
| `touch: cannot touch '.env': Permission denied` and `Aborted (core dumped)` (exit 134) | Container missing one of CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID — the image's root-init phase can't chown `/actions-runner` and drop to the runner user | Verify the `cap_add` block on the runner matches the current compose file, then recreate |
| Runner registers, runs one job, exits, and never comes back | `EPHEMERAL=true` is working as designed — `restart: unless-stopped` should bring it back; if not, check `docker ps -a` for the exit code | Recreate the runner |

### A job sits Queued forever

Check the runner is **Idle** in GitHub UI (not Offline). If Offline:

- `docker ps --filter name=runner-` — is the container running?
- Confirm the workflow `runs-on:` labels match the runner's `LABELS` env var exactly
  (case-sensitive). `nova` is the common label across all runners; the repo-specific
  label discriminates.

### `nova-config-sync` is not reconciling

```bash
docker logs --tail 50 nova-config-sync
```

The loop logs `reconcile failed, will retry in 600s` on any git error but keeps running.
Common causes: network blip, /srv/nova-config not initialised as a git repo, or a `.git`
permissions problem. To force a single immediate reconcile from the host:

```bash
cd /srv/nova-config && git fetch origin && git reset --hard origin/main
```

### Verifying the hardening

Quick smoke tests after `nova.sh up infra`:

```bash
# Runner cannot see the docker socket directly:
docker exec runner-nova-config ls /var/run/docker.sock
# expected: ls: cannot access '/var/run/docker.sock': No such file or directory

# Runner cannot write to the config mount:
docker exec runner-nova-config touch /nova-config/foo
# expected: touch: /nova-config/foo: Read-only file system

# Runner can reach the socket proxy:
docker exec runner-nova-config wget -qO- http://runners-socket-proxy:2375/_ping
# expected: OK
```

### Force a sync-loop test

```bash
cd /srv/nova-config
git reset --hard HEAD~1     # simulate drift
# wait up to 10 min
git log -1 --format=%H      # should match `git ls-remote origin main` again
```

## Design notes — why these decisions

(All locked in 2026-06-05 / 2026-06-12. See the Phase 1 ticket for full rationale.)

- **Runners in `infra/`, not a new `runners/` stack** — runners are infrastructure;
  one fewer stack to remember in `nova.sh`.
- **Upstream image pinned by digest, no custom build** — every byte of the runner image
  comes from a public source we can audit, and the digest pin means upstream cannot
  silently swap behaviour out from under us.
- **PAT in root `.env`, not `infra/secrets/gh_pat`** — uniform secret delivery with the
  rest of nova; no docker-secrets indirection layer to maintain.
- **Sync sidecar replaces GitHub Actions sync workflow** — eliminates a network round-trip
  (push → GH Actions → SSH → host) and an SSH key on the runner side. Reconciles drift
  every 10 min regardless of whether a push happened.
- **No monitoring layer in v1** — `restart: unless-stopped` + ephemeral mode + the
  containerised proxy is the entire health story. Add ntfy/WUD plumbing only if a real
  failure mode surfaces.
