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

# Configure vibe-kanban MCP server in ~/.claude.json.
# Uses Node.js to merge into existing config without overwriting other settings.
node -e "
  const fs = require('fs');
  const path = '/root/.claude.json';
  let config = {};
  try { config = JSON.parse(fs.readFileSync(path, 'utf8')); } catch(e) {}
  config.mcpServers = config.mcpServers || {};
  config.mcpServers.vibe_kanban = {
    command: 'npx',
    args: ['-y', 'vibe-kanban@0.1.43', '--mcp']
  };
  fs.writeFileSync(path, JSON.stringify(config, null, 2));
"
echo "[entrypoint] Configured vibe_kanban MCP server in ~/.claude.json"

exec "$@"
