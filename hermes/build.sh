#!/usr/bin/env bash
# Build the local Hermes Agent images.
#
# Step 1: pull upstream NousResearch/hermes-agent and build it as hermes-agent:upstream.
# Step 2: build the Nova wrapper (hermes-nova:latest) on top — adds docker CLI for
#         talking to the read-only socket-proxy.
#
# Re-run after upstream releases or after editing hermes/Dockerfile.
# Must be executed on the host (this container's socket proxy blocks `docker build`).
#
# Usage:
#   ./hermes/build.sh                       # build both
#   ./hermes/build.sh --upstream-only       # only step 1
#   ./hermes/build.sh --ref v2026.4.23      # pin upstream to a tag/branch/SHA

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_REPO="https://github.com/NousResearch/hermes-agent.git"
UPSTREAM_REF="main"
UPSTREAM_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream-only) UPSTREAM_ONLY=1; shift ;;
    --ref) UPSTREAM_REF="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "==> Building upstream hermes-agent:upstream from ${UPSTREAM_REPO}#${UPSTREAM_REF}"
docker build --pull -t hermes-agent:upstream "${UPSTREAM_REPO}#${UPSTREAM_REF}"

if [[ "$UPSTREAM_ONLY" -eq 1 ]]; then
  echo "==> Done (upstream only)."
  exit 0
fi

echo "==> Building Nova wrapper hermes-nova:latest"
docker build -t hermes-nova:latest -f hermes/Dockerfile hermes/

echo "==> Done. Bring the stack up with: ./nova.sh up hermes"
