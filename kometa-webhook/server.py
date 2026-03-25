#!/usr/bin/env python3
"""Kometa Webhook Trigger Server

Accepts POST /trigger and signals the kometa wrapper to start an immediate run
by writing a trigger file to a shared bind-mounted directory.

Security layers:
  1. Network isolation — container is only on the kometa_webhook internal Docker
     network (internal: true), reachable solely from containers explicitly added
     to that network (currently only movienight-backend).
  2. Optional Bearer token — if WEBHOOK_SECRET is set, every request must carry
     an Authorization: Bearer <secret> header.  Validated with hmac.compare_digest
     to prevent timing-based enumeration attacks.
  3. No published ports — the container binds to its private IP only; nothing
     on the host or the internet can reach it.
  4. Read-only container filesystem except /trigger.
"""
import hmac
import json
import logging
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TRIGGER_FILE = Path(os.environ.get("TRIGGER_FILE", "/trigger/run"))
SECRET = os.environ.get("WEBHOOK_SECRET", "")
PORT = int(os.environ.get("PORT", "9000"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [kometa-webhook] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def _auth_ok(authorization: str) -> bool:
    """Return True if the request is authorised to trigger a run.

    If WEBHOOK_SECRET is not configured, all requests from the (already
    network-isolated) container network are accepted.  When it is set, the
    Authorization header must carry the matching Bearer token.
    """
    if not SECRET:
        return True
    expected = f"Bearer {SECRET}"
    return hmac.compare_digest(authorization.encode(), expected.encode())


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "kometa-webhook/1"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102
        log.info("HTTP %s %s %s", self.address_string(), fmt % args, "")

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/trigger":
            self._send_json(404, {"error": "not found"})
            return

        auth = self.headers.get("Authorization", "")
        if not _auth_ok(auth):
            log.warning(
                "Rejected POST /trigger from %s: invalid Authorization header",
                self.client_address[0],
            )
            self._send_json(401, {"error": "unauthorized"})
            return

        # Consume body to keep the connection tidy; content is informational only.
        content_length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(content_length) if content_length > 0 else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {}

        collection = body.get("collection", "<unknown>")
        log.info(
            "Trigger request from %s (collection=%r)",
            self.client_address[0],
            collection,
        )

        if TRIGGER_FILE.exists():
            log.info("Trigger already pending — skipping duplicate")
            self._send_json(202, {"status": "queued", "note": "run already pending"})
            return

        try:
            TRIGGER_FILE.touch()
        except OSError as exc:
            log.error("Failed to write trigger file %s: %s", TRIGGER_FILE, exc)
            self._send_json(500, {"error": "could not queue run"})
            return

        log.info("Trigger file written — kometa run queued")
        self._send_json(202, {"status": "triggered"})

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})


def main() -> None:
    # Ensure the trigger directory exists (especially on first start).
    TRIGGER_FILE.parent.mkdir(parents=True, exist_ok=True)

    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)

    def _shutdown(signum, frame):  # noqa: ANN001
        log.info("Received signal %s — shutting down", signum)
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    auth_status = "token auth enabled" if SECRET else "no token (network-isolation only)"
    log.info("Listening on port %d — %s", PORT, auth_status)
    server.serve_forever()


if __name__ == "__main__":
    main()
