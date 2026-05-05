# Kandev Evaluation — Deferred (May 2026)

We evaluated [kandev](https://github.com/kdlbs/kandev) as a successor to
vibe-kanban (which is sunsetting) and **decided to stay on vibe-kanban** for
now. The kandev stack file and Dockerfile are kept in the repo but are no
longer in `nova.sh`'s `ALL_STACKS`, so it won't be touched by the usual
`./nova.sh up`/`update` flow.

This doc captures what we learned so the next attempt doesn't start from
scratch.

## Maturity snapshot at the time of evaluation

- 140 stars, 12 forks, 14 open issues
- Created **2026-01-09** — about 16 weeks old when we evaluated
- 38 releases in those 16 weeks (~10/month) — fast pace, frequent regressions
- Active, responsive maintainers (`carlosflorencio`, `jcfs`, `zeval`); fixes ship within days
- Architecture is solid: Go backend, Next.js frontend, ACP protocol adapters,
  native GitHub API integration via `go-github`

## Why we deferred

The product is designed for **`npx kandev` on a developer laptop**, not a
homelab Docker context. Every problem we hit mapped to that mismatch:

| Problem we hit | Root cause |
|---|---|
| `wget: not found` healthcheck | Upstream image ships only `git ca-certificates gosu tini python3 pipx` — no debug tools |
| Empty agent CLI on PATH | Image bundles **no** agent CLIs; `npm install -g @anthropic-ai/claude-code` (or equivalent) must be added in a derived image |
| `models: 0` after a restart | Sharing the `dev_vibe-kanban-claude` volume between vibe-kanban (root) and kandev (uid 1000) caused auth-state staleness |
| `Path is outside the allowed roots` | Repository discovery defaults to `os.UserHomeDir()` (= `/home/kandev` in container); no reliable env-var override (`KANDEV_REPOSITORYDISCOVERY_ROOTS` isn't bound by viper for the nested camelCase key) |
| `git status: exit status 128` | Repos in `vibe-kanban-repos` were owned by uid 0 (root, vibe-kanban writes); kandev's git refused them under "dubious ownership" |
| GitHub auth UI saved nothing visible | UI flow worked silently; the `GITHUB_TOKEN` env-var path is one of three documented auth methods but undocumented as primary |
| Chats failing to start | Open kandev issue [#720](https://github.com/kdlbs/kandev/issues/720) "Agent failing to connect" — same class of problem; unresolved upstream |

None of these are pure kandev bugs. They're symptoms of stretching a laptop
tool into a multi-tenant container service. Vibe-kanban survived this only
because it had been a commercial product with paying container users before
being open-sourced.

## What's left in the repo

- `docker-compose.kandev.yaml` — minimal first-time config (data + repos
  volumes, `ANTHROPIC_API_KEY` for auth, traefik routing)
- `kandev/Dockerfile` — three lines: `FROM`, `USER root`, `npm install -g
  @anthropic-ai/claude-code`
- WUD triggers and the `kandev` stack registration in `nova.sh` are
  **removed** — bring them back when reviving

## To revive

1. Add `kandev` back to `ALL_STACKS` in `nova.sh:47`
2. Add the `WUD_TRIGGER_DOCKERCOMPOSE_KANDEV_*` env block back to the `wud`
   service in `docker-compose.infra.yaml`
3. Set `ANTHROPIC_API_KEY` in `.env`
4. `./nova.sh up kandev`

If extending beyond the minimal config (SSH key mount, shared `.claude`
volume with vibe-kanban, socket-proxy access, read-only arr/tools config
mounts), see git history before commit `9529a0b` for the full wiring.

## When to re-evaluate

Conditions that would make a second attempt cheaper:

- Kandev reaches **v0.50 or v1.0** (currently v0.38) — implies stabilization
- Issue [#720](https://github.com/kdlbs/kandev/issues/720) "Agent failing to
  connect" is closed
- Kandev publishes an "image with agents bundled" (or documents a sidecar
  pattern) — eliminating the derived-image step
- Kandev adds an env var for `repositoryDiscovery.roots` so the homedir
  constraint can be lifted

## Alternatives surveyed

| Tool | Stars | Notes |
|---|---|---|
| **vibe-kanban** (current) | several K | Sunsetting but open-source, community-maintained, no shutdown date. Works in our homelab today. |
| **agent-viewer** (hallucinogen) | 366 | tmux + thin web UI, `git clone && npm install && npm start`. Tailscale-friendly. Smallest surface area. |
| **claude-code-kanban** (NikiforovAll) | newer | Real-time agent state dashboard, observability-focused |
| **Claw-Kanban** (GreenSheep01201) | newer | Multi-agent routing (Claude / Codex / Gemini) with role-based assignment |
| **kanban-code** (langwatch) | 175 | macOS/Windows native app — not Linux, doesn't fit homelab |

If we revisit and decide kandev still isn't ready, **agent-viewer** is the
next candidate — its tmux-shaped simplicity is the cleanest fit for the
homelab pattern.
