#!/usr/bin/env bash
# nova-gate — SSH forced command: the ONLY thing claude-dev's host key can run.
#
# Installed to /usr/local/bin/nova-gate by install-nova-gate.sh, which pins the key in
# authorized_keys as:
#   restrict,from="<claude-dev subnets>",command="/usr/local/bin/nova-gate" ssh-ed25519 … claude-dev-nova-gate
# sshd runs this instead of whatever the client asked for. The request arrives in
# $SSH_ORIGINAL_COMMAND and is only ever used to pick arguments for nova.sh — it is never
# handed to a shell.
#
# Allowed (from claude-dev: `nova <cmd> [stack] [service]`):
#   ps [stack]  |  health  |  heal  |  reconcile
#   up|pull|update [stack]
#   restart|recreate <stack> [service]
#   down <stack>                       (not dev: nothing could bring claude-dev back)
# Refused: config (prints every secret in .env), logs (already at /mnt/nova-logs), init,
# orphans (interactive prompt), restart/recreate of every stack at once, and any flag —
# nova.sh passes extra args straight through to docker compose.
#
# Anything that can recreate claude-dev itself — up/update/restart/recreate on `dev` or on
# every stack — runs detached. The container, and this SSH connection with it, goes away
# mid-run, and nova.sh must not die with it between `rm` and `up`.

set -euo pipefail

NOVA_SH="@NOVA_CONFIG_DIR@/nova.sh"
REQ="${SSH_ORIGINAL_COMMAND:-}"
FROM="${SSH_CLIENT:-local}"
FROM="${FROM%% *}"

audit() { logger -t nova-gate -- "from=${FROM} $*" 2>/dev/null || true; }

deny() {
  audit "DENIED '${REQ}': $1"
  echo "nova-gate: refused: $1" >&2
  echo "nova-gate: usage: nova <ps|health|up|pull|update|restart|recreate|down|heal|reconcile> [stack] [service]" >&2
  exit 1
}

# Whole-string allowlist first: no quotes, $, ;, globs, newlines or anything else a shell
# might care about can get past this, so the word split below is plain and safe.
chars='^[a-z0-9 _-]*$'
[[ "$REQ" =~ $chars ]] || deny "unexpected characters"
read -r -a args <<< "$REQ"
[[ ${#args[@]} -ge 1 ]] || deny "no command"

# No leading '-': a flag would reach docker compose unfiltered.
word='^[a-z0-9][a-z0-9_-]*$'
for a in "${args[@]}"; do
  [[ "$a" =~ $word ]] || deny "bad argument '$a'"
done

cmd="${args[0]}"
stack="${args[1]:-}"

# max = most words allowed, command included; need_stack = stack is mandatory.
need_stack=0
case "$cmd" in
  health|heal|reconcile) max=1 ;;
  ps|up|pull|update)     max=2 ;;
  restart|recreate)      max=3; need_stack=1 ;;
  down)                  max=2; need_stack=1 ;;
  config)                deny "config prints every secret in .env" ;;
  logs)                  deny "read /mnt/nova-logs or use docker logs instead" ;;
  init|orphans)          deny "'$cmd' is host-only" ;;
  *)                     deny "unknown command '$cmd'" ;;
esac
[[ ${#args[@]} -le $max ]] || deny "too many arguments for '$cmd'"
[[ $need_stack -eq 0 || -n "$stack" ]] || deny "'$cmd' needs a stack"

if [[ -n "$stack" ]]; then
  # Read the stack list from nova.sh itself so the two can never drift apart.
  stacks=" $(sed -n 's/^ALL_STACKS=(\(.*\))$/\1/p' "$NOVA_SH") "
  [[ "$stacks" == *" $stack "* ]] || deny "unknown stack '$stack'"
fi

[[ "$cmd" == "down" && "$stack" == "dev" ]] && deny "down dev would take claude-dev offline with no way back"

audit "ALLOWED '${REQ}'"

case "$cmd" in
  up|update|restart|recreate)
    if [[ -z "$stack" || "$stack" == "dev" ]]; then
      echo "nova-gate: '${REQ}' can recreate claude-dev, so it runs detached on the host."
      echo "nova-gate: follow it with: tail -F /mnt/nova-logs/current.log"
      setsid -f "$NOVA_SH" "${args[@]}" </dev/null >/dev/null 2>&1
      exit 0
    fi
    ;;
esac

exec "$NOVA_SH" "${args[@]}"
