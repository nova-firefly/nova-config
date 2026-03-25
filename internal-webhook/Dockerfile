FROM python:3.12-alpine

# su-exec: lightweight setuid-less privilege drop (standard Alpine pattern)
RUN apk add --no-cache su-exec

WORKDIR /app

COPY server.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD wget -qO- http://localhost:9000/health 2>/dev/null || exit 1

# Starts as root only to chown the named volume mount, then drops to nobody.
# See entrypoint.sh for details.
ENTRYPOINT ["/app/entrypoint.sh"]
