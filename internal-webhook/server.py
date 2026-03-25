#!/usr/bin/env python3
"""Internal Webhook Server

A lightweight HTTP server for internal container-to-container webhooks.
Add new POST handlers to POST_HANDLERS to expose additional endpoints.

Security layers:
  1. Network isolation — container is only on the `internal_webhook` Docker
     network (internal: true), reachable solely from containers explicitly
     added to that network.
  2. Optional Bearer token — if WEBHOOK_SECRET is set, every request must
     carry an Authorization: Bearer <secret> header, validated with
     hmac.compare_digest to prevent timing attacks.
  3. No published ports — unreachable from the host or internet.
  4. Read-only container filesystem except the /trigger bind-mount.

Adding a new endpoint:
  1. Write a handler function with signature:
       def _handle_foo(handler: 'WebhookHandler', body: dict) -> None
  2. Register it:
       POST_HANDLERS["/foo/trigger"] = _handle_foo
"""
import hmac
import json
import logging
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Callable, Dict

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SECRET = os.environ.get("WEBHOOK_SECRET", "")
PORT = int(os.environ.get("PORT", "9000"))

# Path to the sentinel file read by kometa/trigger-wrapper.sh
KOMETA_TRIGGER_FILE = Path(os.environ.get("KOMETA_TRIGGER_FILE", "/trigger/run"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [internal-webhook] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _auth_ok(authorization: str) -> bool:
    """Return True if the request is authorised.

    If WEBHOOK_SECRET is not set, all requests from the (already
    network-isolated) internal network are accepted.  When set, the
    Authorization header must carry the matching Bearer token.
    """
    if not SECRET:
        return True
    expected = f"Bearer {SECRET}"
    return hmac.compare_digest(authorization.encode(), expected.encode())


# ---------------------------------------------------------------------------
# Endpoint handlers
# ---------------------------------------------------------------------------

def _handle_kometa_trigger(handler: "WebhookHandler", body: dict) -> None:
    """POST /kometa/trigger — queue an immediate kometa run.

    Writes a sentinel file to the bind-mount shared with the kometa
    container.  trigger-wrapper.sh picks it up within ~5 seconds and
    invokes kometa --run.
    """
    collection = body.get("collection", "<unknown>")
    log.info(
        "Kometa trigger from %s (collection=%r)",
        handler.client_address[0],
        collection,
    )

    if KOMETA_TRIGGER_FILE.exists():
        log.info("Kometa trigger already pending — skipping duplicate")
        handler._send_json(202, {"status": "queued", "note": "run already pending"})
        return

    try:
        KOMETA_TRIGGER_FILE.touch()
    except OSError as exc:
        log.error("Failed to write kometa trigger file %s: %s", KOMETA_TRIGGER_FILE, exc)
        handler._send_json(500, {"error": "could not queue run"})
        return

    log.info("Kometa trigger file written — run queued")
    handler._send_json(202, {"status": "triggered"})


# ---------------------------------------------------------------------------
# Route registry — add new POST handlers here
# ---------------------------------------------------------------------------

POST_HANDLERS: Dict[str, Callable[["WebhookHandler", dict], None]] = {
    "/kometa/trigger": _handle_kometa_trigger,
}


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "internal-webhook/1"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: D102
        log.info("HTTP %s — %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self) -> dict:
        content_length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(content_length) if content_length > 0 else b""
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {}

    def do_POST(self) -> None:  # noqa: N802
        handler = POST_HANDLERS.get(self.path)
        if handler is None:
            self._send_json(404, {"error": "not found"})
            return

        auth = self.headers.get("Authorization", "")
        if not _auth_ok(auth):
            log.warning(
                "Rejected POST %s from %s: invalid Authorization header",
                self.path,
                self.client_address[0],
            )
            self._send_json(401, {"error": "unauthorized"})
            return

        handler(self, self._read_body())

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})


def main() -> None:
    KOMETA_TRIGGER_FILE.parent.mkdir(parents=True, exist_ok=True)

    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)

    def _shutdown(signum, frame):  # noqa: ANN001
        log.info("Received signal %s — shutting down", signum)
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    routes = list(POST_HANDLERS)
    auth_status = "token auth enabled" if SECRET else "no token (network-isolation only)"
    log.info("Listening on port %d — %s | routes: %s", PORT, auth_status, routes)
    server.serve_forever()


if __name__ == "__main__":
    main()
