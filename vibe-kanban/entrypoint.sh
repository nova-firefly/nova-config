#!/bin/sh
set -e

# Install claude-skills into ~/.claude/skills/ on first container run.
# Skills are pre-baked into the image at /opt/claude-skills-staging during build.
MARKER="/root/.claude/skills/.jeffallan-installed"

if [ ! -f "$MARKER" ]; then
  echo "[entrypoint] Installing claude-skills into /root/.claude/skills/ ..."
  mkdir -p /root/.claude/skills
  cp -r /opt/claude-skills-staging/skills/. /root/.claude/skills/
  touch "$MARKER"
  echo "[entrypoint] claude-skills installed."
fi

# Write global CLAUDE.md with auto-skill activation instructions.
# Always overwrite so updates to the image are picked up on restart.
mkdir -p /root/.claude
cp /opt/global-claude.md /root/.claude/CLAUDE.md

exec "$@"
