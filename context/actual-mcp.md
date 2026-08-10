# Actual Budget MCP (SSE) connector

Exposes the self-hosted Actual Budget instance to Claude as a **remote MCP
connector**, reachable from any device signed into the Claude account. Lives in
the **tools** stack as the `actual-mcp` service alongside `actual`.

- **Server:** [`s-stefanov/actual-mcp`](https://github.com/s-stefanov/actual-mcp) (MIT), image `sstefanov/actual-mcp`, pinned to `v1.11.3` (Docker Hub tags are `v`-prefixed; amd64 digest `sha256:76291b13…`). Latest at time of writing is `v1.12.0`.
- **Transport:** legacy two-endpoint HTTP+SSE (`--sse`). SSE is deprecated in the MCP spec but not removed; Claude clients still support it. Migration path if it breaks is at the bottom of this doc.
- **URL:** `https://actual-mcp.${NOVA_DOMAIN}` (Traefik route, TLS at the edge, **no** host ports).

## How it works (and why `actual` is always-on)

The `@actual-app/api` library this server wraps has **no REST API** — it
downloads a *local copy* of the budget into `ACTUAL_DATA_DIR` (`/data`, the
`actual_mcp_data` volume) and syncs changes back. Consequences baked into the
compose config:

- The `/data` volume is **mandatory** — the container won't start without it.
- The first response after a restart is **slow** (full budget download); the
  healthcheck `start_period` is 120s to cover it.
- The MCP reaches the Actual server **directly over `traefik_default` at
  `http://actual:5006`**, which bypasses Traefik and therefore Sablier. So
  `actual` is kept **always-on** (its Sablier labels were removed) — an
  on-demand `actual` would never be woken for an MCP call, and Claude issues
  those calls from the cloud at any time.

## Auth model

Claude reaches custom connectors **from Anthropic's cloud, not from your
device** (true on claude.ai, Desktop, Cowork, and mobile). So:

- The route **must be publicly reachable** and is intentionally **not behind
  Authelia** — a browser SSO can't sit in front of a machine-to-machine API.
- Auth is the MCP server's **bearer token** (`--enable-bearer` + `BEARER_TOKEN`,
  from `MCP_BEARER_TOKEN`). Traefik terminates TLS; the `actual-mcp-sse@file`
  middleware rate-limits the route as defence-in-depth.
- **Do not rely on IP allowlisting.** Anthropic publishes egress ranges, but
  connector traffic has been observed arriving from internal GCP addresses,
  silently breaking origin firewall rules. Treat IP rules as defence-in-depth
  only.

## Setup order

1. **Fill `.env`** (see the *Actual Budget MCP* section in `.env.example`):
   - `ACTUAL_PASSWORD` — your Actual web-UI login password.
   - `ACTUAL_SYNC_ID` — Actual → Settings → Show advanced settings → **Sync ID**.
   - `MCP_BEARER_TOKEN` — `openssl rand -hex 32`.
   - `MCP_PUBLIC_HOSTNAME` — e.g. `actual-mcp.${NOVA_DOMAIN}` (used by the verify script).
   - `ACTUAL_BUDGET_ENCRYPTION_PASSWORD` — only if E2E encryption uses a
     different password than the server login; leave blank otherwise.

   Keep `.env` at `chmod 600`, gitignored (it already is), and never on a synced
   cloud drive.

2. **Confirm backups first** (see *Security posture* below) — before any remote
   write is possible.

3. **Start the service:**
   ```bash
   ./nova.sh up tools           # or: docker compose -f tools/compose.yaml up -d
   ```

4. **Verify** (run on nova — the vibe-kanban socket proxy blocks `exec`):
   ```bash
   bash tools/verify-actual-mcp.sh    # or: chmod +x tools/verify-actual-mcp.sh && ./tools/verify-actual-mcp.sh
   ```
   It checks: `--test-resources` connectivity, a correct token opens the SSE
   stream, a **wrong token is rejected** (hard-fails the script otherwise), and
   the public hostname serves valid TLS.

5. **Debug the server directly** (optional):
   ```bash
   npx @modelcontextprotocol/inspector      # point it at the public URL + bearer header
   ```
   MCP Inspector should list the tools.

6. **Add the connector in Claude** → Settings → Connectors → **Add custom
   connector**:
   - **URL:** `https://actual-mcp.${NOVA_DOMAIN}/sse`
   - **Request headers** (beta — see caveat below): header `Authorization`,
     value `Bearer <MCP_BEARER_TOKEN>` — **include the `Bearer ` scheme and
     space.** Claude sends the value verbatim with no prefix added.

   **Auth caveat:** Claude's connector request-header auth is in beta and rolling
   out gradually. Verify the *Request headers* field exists under *Add custom
   connector* before assuming bearer auth will work. If it's absent, the bearer
   token becomes a secret-in-URL/obscurity measure only — lean harder on the
   read-mostly posture and backups below.

7. **Block mutating tools** on the connector (see below).

## Security posture

- **Backups before first write.** The authoritative budget lives in the
  `actual_data` volume (the `actual` server), *not* the MCP's disposable
  `actual_mcp_data` copy. Ensure `actual_data` (Docker name `tools_actual_data`)
  is included in the **backup** stack (Backrest) with a nightly, versioned,
  30-day-retention job, and **test a restore end to end** before enabling remote
  writes. `actual_mcp_data` needs no backup — it re-downloads on start.
- **Read-mostly remote tier.** After adding the connector, block every mutating
  tool under Claude → **Customize → Connectors → Actual Budget MCP → tool
  permissions**: all `create-*`, `update-*`, and `delete-*` tools (categories,
  category groups, payees, rules, transactions). This is a **client-side**
  control — a leaked token still permits writes, which is why backups come
  first. Apply writes from a **stdio** instance on one trusted machine instead.
- **Token rotation is the kill switch.** Rotating `MCP_BEARER_TOKEN` immediately
  invalidates all remote access:
  ```bash
  # edit MCP_BEARER_TOKEN in .env, then:
  ./nova.sh recreate tools actual-mcp
  ```
  Update the connector's `Authorization` header in Claude afterwards.

## Category-audit use case

Relevant read tools: `get-transactions`, `spending-by-category`,
`monthly-summary`, `get-grouped-categories`, `get-payees`, `get-rules`. There is
**no aggregate-only "uncategorized summary" tool**, so audit prompts must ask
for aggregates explicitly — otherwise raw transaction rows get dumped into
context.

## Known failure modes

| Symptom | Likely cause |
|---|---|
| Container exits on start | Missing `/data` volume, or `BEARER_TOKEN` unset while `--enable-bearer` is on |
| Connector connects then drops | Proxy buffering SSE, or read timeout too short (Traefik doesn't buffer by default; check any override) |
| "Couldn't reach MCP server" | Hostname not publicly resolvable, or an IP allowlist blocking Anthropic |
| Auth fails despite correct token | `Authorization` value entered without the `Bearer ` prefix, or the request-header beta isn't on the account |
| Balances differ from the UI | Stale local copy — sync, or pending future-dated transactions excluded from the balance cutoff |
| Slow first response after restart | Expected; full budget download |

## Rollback

1. Rotate `MCP_BEARER_TOKEN` (kills remote access immediately).
2. Remove the Traefik route (delete the `actual-mcp` labels or the service) —
   kills reachability.
3. `docker compose -f tools/compose.yaml rm -sf actual-mcp` — kills the service.

The `actual` service and its data are untouched throughout. (Reverting `actual`
to on-demand is optional and independent: re-add its Sablier labels and the
`sablier-actual` middleware.)

## Migration path (if SSE is dropped)

This server speaks legacy HTTP+SSE, not Streamable HTTP. If a Claude client
drops SSE support, **keep this image**, run it in **stdio** mode, and front it
with [`supercorp/supergateway`](https://github.com/supercorp-ai/supergateway)
`--outputTransport streamableHttp`. No fork required. (Tracked separately as the
supergateway migration story.)
