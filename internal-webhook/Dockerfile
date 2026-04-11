FROM python:3.12-alpine

# su-exec: lightweight setuid-less privilege drop (standard Alpine pattern)
RUN apk add --no-cache su-exec

WORKDIR /app

COPY server.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9000/health')"

# Starts as root only to chown the named volume mount, then drops to nobody.
# See entrypoint.sh for details.
ENTRYPOINT ["/app/entrypoint.sh"]
