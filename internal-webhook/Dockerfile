FROM python:3.12-alpine

WORKDIR /app

COPY server.py .

# nobody (uid 65534) already exists in Alpine — use it directly.
# /trigger is provided at runtime via a named Docker volume (world-writable
# by default), so no chown is needed here.
USER nobody

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD wget -qO- http://localhost:9000/health 2>/dev/null || exit 1

CMD ["python3", "/app/server.py"]
