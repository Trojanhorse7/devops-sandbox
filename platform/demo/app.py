#!/usr/bin/env python3
"""Minimal demo workload: / and /health for the sandbox platform."""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import json


PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return super().log_message(fmt, *args)

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        env_id = os.environ.get("SANDBOX_ENV_ID", "unknown")
        if self.path in ("/health", "/health/"):
            self._json(
                200,
                {"status": "ok", "sandbox_env_id": env_id},
            )
            return
        if self.path in ("/", ""):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            msg = f"Sandbox demo app (env={env_id})\n"
            self.send_header("Content-Length", str(len(msg.encode())))
            self.end_headers()
            self.wfile.write(msg.encode())
            return
        self.send_error(404)


def main():
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
