#!/usr/bin/env python3
"""Extract a compact research trajectory from Claude Code stream-json output."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def compact_value(value: Any, *, limit: int = 500) -> Any:
    if isinstance(value, str):
        if len(value) <= limit:
            return value
        return value[:limit] + f"... [truncated {len(value) - limit} chars]"
    if isinstance(value, list):
        return [compact_value(item, limit=limit) for item in value[:20]]
    if isinstance(value, dict):
        compact: dict[str, Any] = {}
        for key, item in value.items():
            if key in {"content", "text"} and isinstance(item, str) and len(item) > limit:
                compact[key] = f"[{len(item)} chars]"
            else:
                compact[key] = compact_value(item, limit=limit)
        return compact
    return value


def iter_content_blocks(message: dict[str, Any]) -> list[dict[str, Any]]:
    content = message.get("content", [])
    if isinstance(content, list):
        return [block for block in content if isinstance(block, dict)]
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return []


def tool_focus(name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
    if name == "WebSearch":
        return {"query": tool_input.get("query")}
    if name == "WebFetch":
        return {"url": tool_input.get("url"), "prompt": tool_input.get("prompt")}
    if name in {"Read", "Write"}:
        return {"file_path": tool_input.get("file_path")}
    if name == "Bash":
        return {"command": tool_input.get("command")}
    return compact_value(tool_input)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stream", required=True, type=Path)
    parser.add_argument("--summary-out", required=True, type=Path)
    parser.add_argument("--chat-out", required=True, type=Path)
    args = parser.parse_args()

    assistant_texts: list[str] = []
    result_text = ""
    tool_uses: list[dict[str, Any]] = []
    tool_results: list[dict[str, Any]] = []
    thinking_blocks = 0
    event_counts: dict[str, int] = {}

    for line_number, line in enumerate(args.stream.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_type = str(event.get("type", "unknown"))
        event_counts[event_type] = event_counts.get(event_type, 0) + 1

        if event_type == "assistant":
            message = event.get("message", {})
            if not isinstance(message, dict):
                continue
            for block in iter_content_blocks(message):
                block_type = block.get("type")
                if block_type == "text":
                    text = block.get("text")
                    if isinstance(text, str) and text:
                        assistant_texts.append(text)
                elif block_type == "tool_use":
                    name = str(block.get("name", ""))
                    tool_input = block.get("input", {})
                    if not isinstance(tool_input, dict):
                        tool_input = {"value": tool_input}
                    tool_uses.append(
                        {
                            "line": line_number,
                            "id": block.get("id"),
                            "name": name,
                            "input": tool_focus(name, tool_input),
                        }
                    )
                elif block_type in {"thinking", "redacted_thinking"}:
                    thinking_blocks += 1
        elif event_type == "user":
            message = event.get("message", {})
            if not isinstance(message, dict):
                continue
            for block in iter_content_blocks(message):
                if block.get("type") == "tool_result":
                    content = block.get("content", "")
                    tool_results.append(
                        {
                            "line": line_number,
                            "tool_use_id": block.get("tool_use_id"),
                            "is_error": bool(block.get("is_error", False)),
                            "content_chars": len(content) if isinstance(content, str) else 0,
                        }
                    )
        elif event_type == "result":
            value = event.get("result")
            if isinstance(value, str):
                result_text = value

    search_queries = [
        item["input"].get("query")
        for item in tool_uses
        if item.get("name") == "WebSearch" and isinstance(item.get("input"), dict) and item["input"].get("query")
    ]
    fetch_urls = [
        item["input"].get("url")
        for item in tool_uses
        if item.get("name") == "WebFetch" and isinstance(item.get("input"), dict) and item["input"].get("url")
    ]

    chat_text = result_text.strip() or "\n\n".join(text.strip() for text in assistant_texts if text.strip())
    args.chat_out.write_text(chat_text + ("\n" if chat_text else ""), encoding="utf-8")

    summary = {
        "stream": str(args.stream),
        "chat": str(args.chat_out),
        "event_counts": event_counts,
        "tool_use_count": len(tool_uses),
        "tool_result_count": len(tool_results),
        "thinking_block_count": thinking_blocks,
        "search_queries": search_queries,
        "fetch_urls": fetch_urls,
        "tool_uses": tool_uses,
        "tool_results": tool_results,
        "final_chat_chars": len(chat_text),
    }
    args.summary_out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
