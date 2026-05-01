#!/bin/sh
set -e

# Replaces the upstream entrypoint. Adds chown of /home/kandev/.claude so a
# pre-existing volume populated by vibe-kanban (root-owned) becomes writable
# by uid 1000.
if [ "$(id -u)" = '0' ]; then
    chown -R kandev:kandev /data
    if [ -d /home/kandev/.claude ]; then
        chown -R kandev:kandev /home/kandev/.claude
    fi
    exec gosu kandev "$@"
fi

exec "$@"
