#!/usr/bin/env bash
# Non-destructive verification for the Actual Budget MCP (SSE) connector.
# Safe to run before AND after exposing the connector publicly — it makes no
# writes to the budget.
#
# Run from the host (needs a real Docker socket for the exec check; the
# vibe-kanban read-only socket proxy blocks `exec`, so run this on nova itself):
#   ./tools/verify-actual-mcp.sh
#
# Checks:
#   1. actual-mcp can reach the Actual server        (--test-resources)
#   2. correct bearer token opens an SSE stream       (HTTP 200)
#   3. wrong bearer token is REJECTED                 (HTTP 401/403) — hard fail if not
#   4. public hostname resolves and serves valid TLS
set -uo pipefail

# Resolve repo root (this script lives in tools/) and load .env.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

: "${MCP_BEARER_TOKEN:?MCP_BEARER_TOKEN not set (see .env / .env.example)}"
: "${NOVA_DOMAIN:?NOVA_DOMAIN not set (see .env)}"
HOST="${MCP_PUBLIC_HOSTNAME:-actual-mcp.${NOVA_DOMAIN}}"
BASE="https://${HOST}"
COMPOSE=(docker compose -f tools/compose.yaml)

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- 1. Connectivity from inside the container ------------------------------
info "1. actual-mcp -> Actual server (--test-resources)"
if "${COMPOSE[@]}" exec -T actual-mcp node build/index.js --test-resources; then
  ok "container can reach the Actual server and load the budget"
else
  bad "--test-resources failed (check ACTUAL_PASSWORD / ACTUAL_SYNC_ID / actual up)"
fi

# --- 2. Correct bearer token opens an SSE stream ----------------------------
# The SSE stream stays open, so --max-time aborts the transfer (curl exit 28)
# while %{http_code} still reports the status line that was received.
info "2. Correct bearer token -> SSE stream (expect 200)"
good_code="$(curl -sS -N --max-time 5 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${MCP_BEARER_TOKEN}" "${BASE}/sse" 2>/dev/null || true)"
if [[ "$good_code" == "200" ]]; then
  ok "SSE endpoint returned 200 with a valid token"
else
  bad "expected 200 from ${BASE}/sse with a valid token, got '${good_code:-<none>}'"
fi

# --- 3. Wrong bearer token MUST be rejected ---------------------------------
info "3. Wrong bearer token -> rejected (expect 401/403)"
bad_code="$(curl -sS -N --max-time 5 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer definitely-not-the-token" "${BASE}/sse" 2>/dev/null || true)"
if [[ "$bad_code" == "401" || "$bad_code" == "403" ]]; then
  ok "invalid token rejected with ${bad_code}"
else
  bad "SECURITY: invalid token was NOT rejected (got '${bad_code:-<none>}', expected 401/403)"
fi

# --- 4. Public hostname resolves + valid TLS --------------------------------
info "4. Public hostname resolves and serves valid TLS"
curl -sS -o /dev/null --max-time 10 "${BASE}/" 2>/dev/null
rc=$?
# exit 0 = clean response; 22 = HTTP >=400 (e.g. 401 without a token); 28 =
# timeout on an open stream. In all three TLS was negotiated and validated.
if [[ $rc -eq 0 || $rc -eq 22 || $rc -eq 28 ]]; then
  ok "${HOST} resolves and presents a valid certificate"
else
  bad "TLS/resolution check failed for ${BASE} (curl exit ${rc})"
fi

# --- Summary ----------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
