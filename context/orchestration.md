# Orchestration Decision: Stay on Plain Docker Compose

This file captures the reasoning behind sticking with plain Docker Compose (managed by
`nova.sh` + Dockge) instead of moving to Docker Swarm or k3s. Revisit if the homelab grows
beyond a single host or self-healing requirements outpace what a `reconcile` cron can deliver.

## Current setup (2026-05)

- Single host, ~11 stacks, all defined as `<stack>/compose.yaml`.
- `nova.sh` wraps `docker compose` with batch ops, init, reconcile, ntfy push, orphan detection.
- `nova-reconcile.sh` (host cron) runs `nova.sh reconcile` to recreate any missing containers.
- Dockge provides the mobile UI on top of the same on-disk files.

## Why not Docker Swarm

- **Maintenance mode upstream.** Swarm is no longer actively developed; Mirantis owns it and
  treats it as legacy. New features land on Compose and Kubernetes, not Swarm.
- **Invalidates Dockge.** Dockge drives `docker compose`, not `docker stack deploy`. Moving
  to Swarm would mean abandoning the mobile UI we just adopted, or running both side-by-side.
- **Compose feature drift.** Swarm ignores `container_name`, `depends_on` conditions, build
  contexts, and restart policies in the form Compose uses. Migrating would require touching
  every compose file.
- **Self-healing benefit is small for one node.** Swarm's main self-heal value is rescheduling
  tasks across nodes. On a single host the practical equivalent is `restart: unless-stopped`
  + `nova.sh reconcile` cron, which we already have.

Verdict: Swarm costs more than it returns at this scale. Don't migrate.

## Why not k3s

- **Full manifest rewrite.** Compose YAML doesn't translate 1:1. Each service becomes a
  Deployment + Service + (often) Ingress + PVCs. Realistic migration is days of work per stack
  and produces files that are no longer human-friendly to skim.
- **Different ingress model.** Traefik labels go away; routes become Ingress or IngressRoute
  CRDs. Authelia integration also changes shape (auth middlewares become annotations).
- **Storage model is heavier.** Bind mounts and named volumes become PVCs backed by a
  StorageClass; either we run local-path-provisioner (similar to bind mounts but with extra
  abstraction) or stand up something like Longhorn.
- **Invalidates Dockge.** Same as Swarm — Dockge can't drive Kubernetes.
- **Real benefits exist** but mostly matter at multi-node scale: rolling deployments, true
  self-healing across nodes, declarative state, GitOps via Flux/ArgoCD.

Verdict: Higher upside than Swarm if we ever leave Compose, but the migration cost is
significant and only pays off at multi-node scale or with a real GitOps workflow.

## "If we ever leave Compose" guidance

- Don't go Swarm. It's a dead end.
- Go k3s, and treat it as a from-scratch redesign rather than a port. The Compose files stop
  being the source of truth; Kustomize/Helm + a Git-backed reconciler become the source of
  truth instead.
- Triggers that would justify the cost: a second host, a need for zero-downtime rolling
  deploys, or a workflow where "merge to main → cluster converges" is a hard requirement.

## Self-healing today

The current substitute for orchestrator self-healing is:

1. `restart: unless-stopped` on every service — handles process crashes.
2. Healthchecks on services that support them — surface bad states to Dockge / Homepage / WUD.
3. `nova.sh reconcile` (cron) — recreates any container that's defined in a compose file but
   missing from `docker ps`. Catches the "someone manually `docker rm`'d a container" case.
4. Uptime Kuma + ntfy — alert on user-visible outages.

This is not equivalent to Kubernetes-style self-healing (it can't move workloads off a sick
node), but on a single host the failure modes it doesn't cover are the same failure modes
that would also kill a single-node k3s cluster.
