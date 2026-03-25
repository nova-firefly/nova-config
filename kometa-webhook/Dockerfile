FROM python:3.12-alpine

WORKDIR /app

COPY server.py .

# Create non-root user and trigger directory
RUN adduser -D -u 65534 webhook && \
    mkdir -p /trigger && \
    chown webhook:webhook /trigger

USER 65534

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD wget -qO- http://localhost:9000/health 2>/dev/null || exit 1

CMD ["python3", "/app/server.py"]
