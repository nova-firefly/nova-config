# Claude Skills — Role Selection Guide

Claude skills from [Jeffallan/claude-skills](https://github.com/Jeffallan/claude-skills) are installed in the
vibe-kanban container at `~/.claude/skills/`. Each skill defines a specialized expert persona.

Use the guidance below to select the right skill for each type of task in this homelab project.

## How to Activate a Skill

In Claude Code, prefix your request with the skill name or describe your task in terms that match the skill:
- `/skill devops-engineer` — activate by name
- Or just describe the task; Claude will engage the relevant skill automatically

---

## Task → Skill Mapping

### Docker Compose & Stack Management
**Skill:** `devops-engineer`
- Adding/modifying services in any `docker-compose.<stack>.yaml`
- Writing healthchecks, resource constraints, cap_drop lists
- Traefik label configuration
- Updating `nova.sh` or WUD triggers
- Reviewing compose file correctness and security

### Infrastructure Security Hardening
**Skill:** `secure-code-guardian` + `security-reviewer`
- Reviewing cap_drop lists and privilege escalation risks
- Auditing Traefik routing rules for exposure issues
- Checking secrets handling in `.env` and compose files
- Reviewing network isolation (internal networks, socket proxy)

### Debugging Container / Service Issues
**Skill:** `debugging-wizard`
- Diagnosing why a service won't start or fails healthchecks
- Tracing network routing issues through Traefik
- Investigating WUD update failures
- Volume mount or permission problems

### PostgreSQL (Immich, Movienight)
**Skill:** `postgres-pro`
- Optimizing immich-postgres queries or configuration
- Movienight DB schema changes
- Backup/restore strategies for postgres containers
- pgvecto-rs (vector extension) configuration for Immich

### Movienight Frontend (React)
**Skill:** `react-expert`
- Changes to `movienight/frontend/` React components
- UI/UX improvements to the movie suggestion app

### Movienight Backend (GraphQL API)
**Skill:** `graphql-architect`
- Schema changes, resolver logic, federation patterns
- API performance and N+1 query issues

### Monitoring & Observability
**Skill:** `monitoring-expert`
- Configuring Glances dashboards
- Tautulli metrics and alerting
- Homepage widget configuration
- Setting up alerting via WUD/Discord

### Reliability & Incident Response
**Skill:** `sre-engineer`
- Designing backup strategies (Backrest/Duplicati)
- SLO/uptime targets for critical services
- Runbooks for service recovery
- On-call and alerting setup

### CLI Tools & Shell Scripts
**Skill:** `cli-developer`
- Improving `nova.sh` commands and UX
- Writing helper scripts for stack management
- Shell scripting best practices

### Home Assistant (Automations / Config)
**Skill:** `python-pro`
- Home Assistant YAML automations are Python-adjacent; use for complex automation logic
- Scripting HA integrations or custom components

### TypeScript/JavaScript (Vibe Kanban, General)
**Skill:** `typescript-pro`
- Working on vibe-kanban source code
- Type safety improvements
- Node.js patterns

### Architecture Decisions
**Skill:** `architecture-designer`
- Deciding whether to add a new stack vs. service to existing stack
- Evaluating trade-offs between self-hosted solutions
- Writing Architecture Decision Records (ADRs)

### Challenging Assumptions
**Skill:** `the-fool`
- Use when you want Claude to critically examine a design decision
- Good for stress-testing proposed architectures or configurations

---

## Multi-Skill Workflows

Some tasks benefit from chaining skills:

| Task | Skills to Chain |
|------|----------------|
| Add new self-hosted service securely | `devops-engineer` → `secure-code-guardian` |
| Investigate + fix a broken service | `debugging-wizard` → `devops-engineer` |
| Design + implement new stack | `architecture-designer` → `devops-engineer` |
| Audit homelab security posture | `security-reviewer` → `secure-code-guardian` |
| Movienight full-stack feature | `react-expert` → `graphql-architect` → `postgres-pro` |

---

## Less Relevant Skills (for Reference)

These exist in the skills library but have limited use in this homelab context:
- `kubernetes-specialist` — not using K8s (Docker Compose only)
- `terraform-engineer` — infrastructure is managed via compose files, not Terraform
- `cloud-architect` — fully self-hosted, no cloud dependency
- `salesforce-developer`, `shopify-expert`, `wordpress-pro` — not applicable
