#!/usr/bin/env python3
"""Forward Anthropic-compatible requests with OpenRouter-specific body additions."""

from __future__ import annotations

import argparse
import http.client
import json
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, ClassVar
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
    server_tools: ClassVar[list[dict[str, Any]]]

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

    def should_mutate_body(self) -> bool:
        path = self.forward_path().split("?", 1)[0].rstrip("/")
        return (
            path.endswith("/v1/messages")
            or path.endswith("/chat/completions")
            or path.endswith("/responses")
        )

    def should_transform_models_response(self) -> bool:
        path = self.forward_path().split("?", 1)[0].rstrip("/")
        return self.command == "GET" and path.endswith("/models")

    def request_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        if not body or self.command != "POST" or not self.should_mutate_body():
            return body
        content_type = self.headers.get("Content-Type", "")
        if "json" not in content_type.lower():
            return body
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            return body
        if not isinstance(payload, dict):
            return body

        changed = False
        if self.service_tier and "service_tier" not in payload:
            payload["service_tier"] = self.service_tier
            changed = True

        if self.server_tools:
            tools = payload.get("tools")
            if tools is None:
                payload["tools"] = self.server_tools
                changed = True
            elif isinstance(tools, list):
                existing_types = {
                    tool.get("type")
                    for tool in tools
                    if isinstance(tool, dict) and isinstance(tool.get("type"), str)
                }
                missing_tools = [
                    tool for tool in self.server_tools if str(tool.get("type", "")) not in existing_types
                ]
                if missing_tools:
                    payload["tools"] = [*tools, *missing_tools]
                    changed = True

        if not changed:
            return body
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def forward(self) -> None:
        body = self.request_body()
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
            and key.lower() != "accept-encoding"
        }
        if body:
            headers["Content-Length"] = str(len(body))
        else:
            headers.pop("Content-Length", None)
        headers["Host"] = self.upstream_host

        connection_class = (
            http.client.HTTPSConnection
            if self.upstream_scheme == "https"
            else http.client.HTTPConnection
        )
        connection = connection_class(self.upstream_host, self.upstream_port, timeout=600)
        try:
            connection.request(self.command, self.forward_path(), body=body, headers=headers)
            response = connection.getresponse()
            if self.should_transform_models_response():
                response_body = response.read()
                transformed_body = transform_models_response(response_body)
                if transformed_body is not None:
                    response_body = transformed_body
                self.send_response(response.status, response.reason)
                for key, value in response.getheaders():
                    lower = key.lower()
                    if lower in HOP_BY_HOP_HEADERS or lower in {"content-length"}:
                        continue
                    if transformed_body is not None and lower in {"content-encoding", "content-type", "etag"}:
                        continue
                    self.send_header(key, value)
                if transformed_body is not None:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response_body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(response_body)
                self.wfile.flush()
                return

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


def transform_models_response(body: bytes) -> bytes | None:
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict) or "models" in payload:
        return None
    data = payload.get("data")
    if not isinstance(data, list):
        return None

    models = [openrouter_to_codex_model(item) for item in data if isinstance(item, dict)]
    codex_payload = {
        "fetched_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "etag": "",
        "client_version": "openrouter-proxy",
        "models": models,
    }
    return json.dumps(codex_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def openrouter_to_codex_model(model: dict[str, Any]) -> dict[str, Any]:
    slug = str(model.get("id") or model.get("canonical_slug") or model.get("name") or "unknown")
    display_name = str(model.get("name") or slug)
    description = str(model.get("description") or "")
    context_window = model_context_window(model)
    supported_parameters = model.get("supported_parameters")
    if not isinstance(supported_parameters, list):
        supported_parameters = []

    return {
        "slug": slug,
        "display_name": display_name,
        "description": description,
        "default_reasoning_level": "medium",
        "supported_reasoning_levels": [
            {"effort": "low", "description": "Fast responses with lighter reasoning"},
            {"effort": "medium", "description": "Balances speed and reasoning depth"},
            {"effort": "high", "description": "Greater reasoning depth for complex tasks"},
            {"effort": "xhigh", "description": "Extra high reasoning depth for complex tasks"},
        ],
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 0,
        "additional_speed_tiers": [],
        "service_tiers": [],
        "availability_nux": {"message": ""},
        "upgrade": None,
        "base_instructions": "You are Codex, a coding agent. Follow the user request and use the available tools carefully.",
        "context_window": context_window,
        "max_context_window": context_window,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": model_input_modalities(model),
        "apply_patch_tool_type": "freeform",
        "default_reasoning_summary": "none",
        "default_verbosity": "low",
        "support_verbosity": True,
        "supports_image_detail_original": "image" in model_input_modalities(model),
        "supports_parallel_tool_calls": any(
            str(parameter) in {"tools", "tool_choice", "parallel_tool_calls"}
            for parameter in supported_parameters
        ),
        "supports_reasoning_summaries": "reasoning" in supported_parameters,
        "supports_search_tool": False,
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "web_search_tool_type": "text_and_image",
    }


def model_context_window(model: dict[str, Any]) -> int:
    top_provider = model.get("top_provider")
    if isinstance(top_provider, dict):
        value = positive_int(top_provider.get("context_length"))
        if value is not None:
            return value
    value = positive_int(model.get("context_length"))
    if value is not None:
        return value
    return 128000


def model_input_modalities(model: dict[str, Any]) -> list[str]:
    modalities = ["text"]
    architecture = model.get("architecture")
    if isinstance(architecture, dict):
        input_modalities = architecture.get("input_modalities")
        if isinstance(input_modalities, list) and "image" in input_modalities:
            modalities.append("image")
    return modalities


def positive_int(value: Any) -> int | None:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://openrouter.ai/api")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--service-tier", default="")
    parser.add_argument("--web-search", action="store_true")
    parser.add_argument("--web-search-engine", default="")
    parser.add_argument("--web-search-max-results", type=int)
    parser.add_argument("--web-search-max-total-results", type=int)
    parser.add_argument("--web-search-context-size", choices=["low", "medium", "high"])
    parser.add_argument("--web-search-allowed-domains", default="")
    parser.add_argument("--web-search-excluded-domains", default="")
    parser.add_argument("--web-fetch", action="store_true")
    parser.add_argument("--web-fetch-engine", default="")
    parser.add_argument("--web-fetch-max-uses", type=int)
    parser.add_argument("--web-fetch-max-content-tokens", type=int)
    parser.add_argument("--web-fetch-allowed-domains", default="")
    parser.add_argument("--web-fetch-blocked-domains", default="")
    args = parser.parse_args()

    parsed = urlparse(args.base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise SystemExit(f"invalid --base-url: {args.base_url}")
    for name, value in (
        ("--web-search-max-results", args.web_search_max_results),
        ("--web-search-max-total-results", args.web_search_max_total_results),
        ("--web-fetch-max-uses", args.web_fetch_max_uses),
        ("--web-fetch-max-content-tokens", args.web_fetch_max_content_tokens),
    ):
        if value is not None and value < 1:
            raise SystemExit(f"{name} must be a positive integer")

    ProxyHandler.upstream_scheme = parsed.scheme
    ProxyHandler.upstream_host = parsed.hostname
    ProxyHandler.upstream_port = parsed.port
    ProxyHandler.upstream_base_path = parsed.path.rstrip("/")
    ProxyHandler.service_tier = args.service_tier
    ProxyHandler.server_tools = build_server_tools(args)

    server = ThreadingHTTPServer((args.host, args.port), ProxyHandler)
    args.port_file.parent.mkdir(parents=True, exist_ok=True)
    args.port_file.write_text(str(server.server_port) + "\n", encoding="utf-8")
    print(
        f"openrouter-proxy: listening on {args.host}:{server.server_port}, "
        f"upstream={args.base_url}, service_tier={args.service_tier or 'none'}, "
        f"server_tools={server_tool_names(ProxyHandler.server_tools)}",
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


def comma_list(value: str) -> list[str] | None:
    items = [item.strip() for item in value.split(",") if item.strip()]
    return items or None


def server_tool_names(tools: list[dict[str, Any]]) -> str:
    return ",".join(str(tool["type"]) for tool in tools) or "none"


def build_web_search_tool(args: argparse.Namespace) -> dict[str, Any]:
    parameters: dict[str, Any] = {}
    if args.web_search_engine:
        parameters["engine"] = args.web_search_engine
    if args.web_search_max_results is not None:
        parameters["max_results"] = args.web_search_max_results
    if args.web_search_max_total_results is not None:
        parameters["max_total_results"] = args.web_search_max_total_results
    if args.web_search_context_size:
        parameters["search_context_size"] = args.web_search_context_size
    allowed_domains = comma_list(args.web_search_allowed_domains)
    if allowed_domains:
        parameters["allowed_domains"] = allowed_domains
    excluded_domains = comma_list(args.web_search_excluded_domains)
    if excluded_domains:
        parameters["excluded_domains"] = excluded_domains

    tool: dict[str, Any] = {"type": "openrouter:web_search"}
    if parameters:
        tool["parameters"] = parameters
    return tool


def build_web_fetch_tool(args: argparse.Namespace) -> dict[str, Any]:
    parameters: dict[str, Any] = {}
    if args.web_fetch_engine:
        parameters["engine"] = args.web_fetch_engine
    if args.web_fetch_max_uses is not None:
        parameters["max_uses"] = args.web_fetch_max_uses
    if args.web_fetch_max_content_tokens is not None:
        parameters["max_content_tokens"] = args.web_fetch_max_content_tokens
    allowed_domains = comma_list(args.web_fetch_allowed_domains)
    if allowed_domains:
        parameters["allowed_domains"] = allowed_domains
    blocked_domains = comma_list(args.web_fetch_blocked_domains)
    if blocked_domains:
        parameters["blocked_domains"] = blocked_domains

    tool: dict[str, Any] = {"type": "openrouter:web_fetch"}
    if parameters:
        tool["parameters"] = parameters
    return tool


def build_server_tools(args: argparse.Namespace) -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []
    if args.web_search:
        tools.append(build_web_search_tool(args))
    if args.web_fetch:
        tools.append(build_web_fetch_tool(args))
    return tools


if __name__ == "__main__":
    raise SystemExit(main())
