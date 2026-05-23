#!/usr/bin/env python3
"""Forward Anthropic-compatible requests to OpenRouter with service_tier set."""

from __future__ import annotations

import argparse
import http.client
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar
from urllib.parse import urlparse


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class ProxyHandler(BaseHTTPRequestHandler):
    upstream_scheme: ClassVar[str]
    upstream_host: ClassVar[str]
    upstream_port: ClassVar[int | None]
    upstream_base_path: ClassVar[str]
    service_tier: ClassVar[str]

    protocol_version = "HTTP/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"openrouter-proxy: {self.address_string()} - {fmt % args}", file=sys.stderr)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        self.forward()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        self.forward()

    def forward_path(self) -> str:
        base = self.upstream_base_path.rstrip("/")
        if base and self.path.startswith(base + "/"):
            return self.path
        if base:
            return base + self.path
        return self.path

    def request_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        if not body or self.command != "POST" or not self.service_tier:
            return body
        content_type = self.headers.get("Content-Type", "")
        if "json" not in content_type.lower():
            return body
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            return body
        if not isinstance(payload, dict) or "service_tier" in payload:
            return body
        payload["service_tier"] = self.service_tier
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def forward(self) -> None:
        body = self.request_body()
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
        }
        if body:
            headers["Content-Length"] = str(len(body))
        else:
            headers.pop("Content-Length", None)
        headers["Host"] = self.upstream_host

        connection_class = http.client.HTTPSConnection if self.upstream_scheme == "https" else http.client.HTTPConnection
        connection = connection_class(self.upstream_host, self.upstream_port, timeout=600)
        try:
            connection.request(self.command, self.forward_path(), body=body, headers=headers)
            response = connection.getresponse()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP_HEADERS or lower in {"content-length"}:
                    continue
                self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://openrouter.ai/api")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--service-tier", default="flex")
    args = parser.parse_args()

    parsed = urlparse(args.base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise SystemExit(f"invalid --base-url: {args.base_url}")

    ProxyHandler.upstream_scheme = parsed.scheme
    ProxyHandler.upstream_host = parsed.hostname
    ProxyHandler.upstream_port = parsed.port
    ProxyHandler.upstream_base_path = parsed.path.rstrip("/")
    ProxyHandler.service_tier = args.service_tier

    server = ThreadingHTTPServer((args.host, args.port), ProxyHandler)
    args.port_file.parent.mkdir(parents=True, exist_ok=True)
    args.port_file.write_text(str(server.server_port) + "\n", encoding="utf-8")
    print(
        f"openrouter-proxy: listening on {args.host}:{server.server_port}, "
        f"upstream={args.base_url}, service_tier={args.service_tier}",
        file=sys.stderr,
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
