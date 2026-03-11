# Global Claude Configuration

## Auto-Skill Activation

Before responding to any technical request, automatically determine the most relevant expert
skill from `~/.claude/skills/` based on the task description and adopt that persona — no need
for the user to specify a role explicitly.

Use the following signals to pick the right skill:

| Task signals | Skill to activate |
|---|---|
| Docker Compose, container config, Traefik labels, stack management, Dockerfile | `devops-engineer` |
| Service won't start, healthcheck failing, networking issue, logs investigation | `debugging-wizard` |
| Security audit, cap_drop, secrets handling, CVE, vulnerability, hardening | `security-reviewer` + `secure-code-guardian` |
| PostgreSQL, database schema, query performance, replication | `postgres-pro` |
| React component, frontend UI, CSS, JSX/TSX | `react-expert` |
| GraphQL schema, resolver, API query | `graphql-architect` |
| Architecture trade-off, design decision, ADR | `architecture-designer` |
| TypeScript types, Node.js, npm | `typescript-pro` |
| Shell script, CLI tool, bash | `cli-developer` |
| Metrics, dashboards, alerting, logging, observability | `monitoring-expert` |
| Reliability, uptime, backup, incident response, SLO | `sre-engineer` |
| General Python, automation scripts | `python-pro` |
| Challenging a decision, devil's advocate | `the-fool` |

When a task spans multiple domains (e.g. adding a new service securely), chain the relevant
skills in sequence. State which skill(s) you are applying at the start of your response.

If the task is ambiguous, default to `devops-engineer` since this is a Docker Compose homelab.
