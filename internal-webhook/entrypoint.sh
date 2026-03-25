#!/bin/sh
set -e
# Container starts as root solely to fix the named-volume ownership.
# Named volumes are created root:root 755 by Docker; nobody can't write to them.
# su-exec then replaces this shell with the server process running as nobody,
# so no root process remains after startup.
chown nobody:nobody /trigger
exec su-exec nobody python3 /app/server.py
