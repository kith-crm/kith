#!/usr/bin/env python3
"""Minimal fake S3 for test/playwright/image-fallback.spec.ts.

Usage: python3 fake_s3.py <log-file> [data-dir] [port]

Serves path-style GET/HEAD /<bucket>/<key> from <data-dir> (default: ./s3-data),
404 for missing keys, PUT stores objects. SigV4 query params are ignored (no
signature validation). Every request line is appended to <log-file>.
Default port: 9000. Dependency-free (stdlib only).
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

LOG = sys.argv[1] if len(sys.argv) > 1 else "s3.log"
ROOT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "s3-data")
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 9000
MAX_PUT_BYTES = 10 * 1024 * 1024  # larger PUT bodies are refused with 413


class Handler(BaseHTTPRequestHandler):
    def _path(self):
        rel = unquote(urlparse(self.path).path).lstrip("/")
        if "\0" in rel:
            return None
        try:
            full = os.path.abspath(os.path.join(ROOT, rel))
        except (ValueError, OSError):
            return None
        return full if full.startswith(ROOT + os.sep) else None

    def _log(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")

    def _empty(self, status):
        self.send_response(status)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _serve(self, head):
        self._log()
        p = self._path()
        if p is None:
            self._empty(400)
            return
        if not os.path.isfile(p):
            self.send_response(404)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(p, "rb") as f:
            data = f.read()
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "image/png" if p.endswith(".png") else "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)

    def do_OPTIONS(self):
        self._log()
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def do_PUT(self):
        self._log()
        p = self._path()
        if not p:
            self._empty(400)
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
        except ValueError:
            n = -1
        if n < 0:
            self._empty(400)
            return
        if n > MAX_PUT_BYTES:
            self.close_connection = True  # body is not read
            self._empty(413)
            return
        body = self.rfile.read(n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(body)
        self.send_response(200)
        self._cors()
        self.send_header("ETag", '"fake"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
