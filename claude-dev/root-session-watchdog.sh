#!/bin/sh
# Re-create a repo's root session when it dies underneath a healthy server.
#
# `--create-session-in-dir` (on by default) pre-creates ONE session in the
# server's working directory — at server start, and only then. That session is
# the repo's "always somewhere to type" entry; everything spawned from the app
# afterwards lands in its own worktree instead.
#
# Nothing recreates it if it ends. Archive it from the app, or let it crash,
# and the server carries on serving worktree sessions while the repo quietly
# loses its root session until the container is restarted. entrypoint.sh's
# supervise() cannot notice: it only relaunches when the SERVER exits, and the
# server did not.
#
# Adopting the dead session by id — the trick entrypoint.sh uses to recover
# worktree sessions across a restart — is the wrong tool here. It resurrects
# the ended conversation, where the point of the root session is that it is a
# fresh empty one. So instead: restart that repo's server and let supervise()
# rebuild the session the same way it does at boot.
#
# Restarting a server drops every session it is holding, so the restart waits
# until the server has none. A repo whose root session died while you are
# working in a worktree therefore stays as it is until that work ends, which
# is the intended trade: never trade live work for an empty session.
#
# Usage: root-session-watchdog.sh <repo-name> [<repo-name> ...]
#   Names are as entrypoint.sh discovered them under $CLAUDE_DEV_REPOS_ROOT,
#   including the literal "." it uses for the no-repos-found fallback.
set -e

REPOS_ROOT="${CLAUDE_DEV_REPOS_ROOT:-/repos}"
CLAUDE_DIR="/root/.claude"
STATE_DIR="/run/claude-dev-watchdog"

# How often to look, and the floor between two restarts of the same server.
# The cooldown is what keeps a root session that dies on every boot from
# turning into a restart loop: worst case it costs one restart per cooldown.
POLL="${CLAUDE_DEV_WATCHDOG_INTERVAL:-60}"
COOLDOWN="${CLAUDE_DEV_WATCHDOG_COOLDOWN:-600}"

log() { echo "[watchdog] $*"; }

# Transcripts live in ~/.claude/projects/<path with / . _ all mapped to ->.
# Same mapping as transcript_dir_for() in entrypoint.sh; kept in step with it.
transcript_dir_for() {
  echo "${CLAUDE_DIR}/projects/$(echo "$1" | tr '/._' '---')"
}

# True when $1 is a live remote-control SERVER for repo label $2.
#
# The pointer file records the pid that wrote it, but pids are recycled and a
# server that is mid-relaunch leaves a stale one behind, so confirm before
# acting on it. --spawn is what separates a server from an adopter (which uses
# --session-id); the label pins it to this repo rather than a sibling's.
is_server() {
  _cmdline="/proc/$1/cmdline"
  [ -r "$_cmdline" ] || return 1
  _argv=$(tr '\0' '\n' < "$_cmdline" 2>/dev/null) || return 1
  echo "$_argv" | grep -qx -- 'remote-control' || return 1
  echo "$_argv" | grep -qx -- '--spawn' || return 1
  echo "$_argv" | grep -qx -- "$2" || return 1
  return 0
}

read_state() {  # $1 = file, prints its contents or 0
  _v=$(cat "$1" 2>/dev/null) || _v=0
  [ -n "$_v" ] || _v=0
  echo "$_v"
}

mkdir -p "$STATE_DIR"
log "watching root sessions for:$(for n in "$@"; do printf ' %s' "$n"; done) (every ${POLL}s)"

while true; do
  # Sleep first: at startup the servers have not written their pointer files
  # yet, and a missing pointer is indistinguishable from a dead session.
  sleep "$POLL"

  for name in "$@"; do
    if [ "$name" = "." ]; then
      dir="$REPOS_ROOT"
      label="${CLAUDE_DEV_SESSION_NAME:-nova}"
    else
      dir="${REPOS_ROOT}/${name}"
      label="$name"
    fi

    pointer="$(transcript_dir_for "$dir")/bridge-pointer.json"
    [ -f "$pointer" ] || continue

    sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$pointer")
    srv=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$pointer")
    [ -n "$sid" ] && [ -n "$srv" ] || continue

    # Stale pointer — the server is gone or being relaunched by supervise().
    # It will rewrite this file with a fresh session once it is back.
    is_server "$srv" "$label" || continue

    miss_file="${STATE_DIR}/${label}.miss"

    # The pointer spells the session session_<ulid>; the runner process that
    # serves it carries the same ulid as cse_<ulid> on its command line.
    if pgrep -f -- "cse_${sid#session_}" >/dev/null 2>&1; then
      rm -f "$miss_file"
      continue
    fi

    # Two consecutive misses before acting, so a session still coming up right
    # after a server relaunch is never mistaken for a dead one.
    miss=$(( $(read_state "$miss_file") + 1 ))
    echo "$miss" > "$miss_file"
    [ "$miss" -ge 2 ] || continue

    if pgrep -P "$srv" -f -- '--session-id cse_' >/dev/null 2>&1; then
      log "[${label}] root session ${sid} is gone, but the server is serving other sessions — deferring restart until they end"
      continue
    fi

    now=$(date +%s)
    restart_file="${STATE_DIR}/${label}.restart"
    last=$(read_state "$restart_file")
    if [ $(( now - last )) -lt "$COOLDOWN" ]; then
      log "[${label}] root session ${sid} is gone, but the server was restarted $(( now - last ))s ago — waiting out the ${COOLDOWN}s cooldown"
      continue
    fi

    log "[${label}] root session ${sid} has no runner and the server is idle; restarting server pid ${srv} to re-create it"
    echo "$now" > "$restart_file"
    rm -f "$miss_file"
    # supervise() is wait()ing on this pid: it logs the exit and relaunches
    # after 10s, and the new server pre-creates a fresh root session.
    kill -TERM "$srv" 2>/dev/null || log "[${label}] server pid ${srv} vanished before it could be signalled"
  done
done
