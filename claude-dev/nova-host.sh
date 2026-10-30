#!/bin/sh
# nova — run nova.sh on the host from inside claude-dev, through the nova-gate forced command.
#   nova ps dev
#   nova up media
#   nova recreate dev claude-dev
# This is only transport. The host decides what is allowed (host-scripts/nova-gate.sh),
# and the key + ssh_config are written into the volume by host-scripts/install-nova-gate.sh.
CFG=/root/.claude/nova-gate/ssh_config

if [ ! -f "$CFG" ]; then
  echo "nova: gate not installed. On the host: sudo ./host-scripts/install-nova-gate.sh" >&2
  exit 1
fi

# `--` before the destination: OpenSSH otherwise keeps parsing options AFTER it, so
# `nova -o ...` would be read as ssh flags rather than sent to the gate (which refuses them).
exec ssh -F "$CFG" -- nova "$@"
