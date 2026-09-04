#!/bin/sh
# Healthy when every server the entrypoint started is still alive.
#
# A bare "is any server alive" check would report healthy while N-1 of N repos
# sat permanently dead, so compare against the count written at startup.
#
# Two subtleties in the pgrep pattern, both load-bearing:
#   - Match 'remote-control', not 'claude remote-control': the running process
#     is `node .../claude-code/cli.js remote-control ...`, so those two words
#     are never adjacent on the command line.
#   - The [r] bracket stops pgrep matching this script's own shell, whose
#     command line would otherwise contain the pattern verbatim — which would
#     report healthy no matter what.
EXPECTED_FILE="/run/claude-dev-expected"

expected=$(cat "$EXPECTED_FILE" 2>/dev/null) || expected=1
[ -n "$expected" ] || expected=1

# NB: `pgrep -fc` prints 0 AND exits 1 when nothing matches, so the obvious
# `$(pgrep -fc ... || echo 0)` yields TWO lines ("0\n0") and the comparison
# below dies with "Illegal number" — precisely in the all-servers-dead case
# this check exists to catch. Assign first, default after.
live=$(pgrep -fc '[r]emote-control' 2>/dev/null) || live=0
[ -n "$live" ] || live=0

if [ "$live" -ge "$expected" ]; then
  exit 0
fi

echo "unhealthy: ${live}/${expected} remote-control server(s) alive"
exit 1
