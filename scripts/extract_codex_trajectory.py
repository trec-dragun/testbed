#!/usr/bin/env python3
"""Extract a compact research trajectory from Codex exec --json output."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def compact(value: Any, *, limit: int = 500) -> Any:
    if isinstance(value, str):
        if len(value) <= limit:
            return value
        return value[:limit] + f"... [truncated {len(value) - limit} chars]"
    if isinstance(value, list):
        return [compact(item, limit=limit) for item in value[:20]]
    if isinstance(value, dict):
        return {
            str(key): compact(item, limit=limit)
            for key, item in list(value.items())[:30]
            if key not in {"content", "text"} or not isinstance(item, str) or len(item) <= limit
        }
    return value


def item_kind(item: dict[str, Any]) -> str:
    kind = item.get("type") or item.get("item_type")
    return str(kind or "")


def item_focus(item: dict[str, Any]) -> dict[str, Any]:
    kind = item_kind(item)
    if kind == "agent_message":
        return {"text_chars": len(str(item.get("text", "")))}
    if kind == "command_execution":
        return {
            "command": item.get("command"),
            "exit_code": item.get("exit_code"),
            "status": item.get("status"),
        }
    if kind == "file_change":
        return {"path": item.get("path"), "status": item.get("status")}
    if kind == "web_search":
        return {"query": item.get("query"), "status": item.get("status")}
    if kind == "mcp_tool_call":
        return {
            "server": item.get("server"),
            "tool": item.get("tool"),
            "arguments": compact(item.get("arguments")),
            "status": item.get("status"),
        }
    return compact(item)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stream", required=True, type=Path)
    parser.add_argument("--summary-out", required=True, type=Path)
    parser.add_argument("--chat-out", required=True, type=Path)
    parser.add_argument("--last-message", type=Path)
    args = parser.parse_args()

    event_counts: dict[str, int] = {}
    item_counts: dict[str, int] = {}
    completed_items: list[dict[str, Any]] = []
    agent_messages: list[str] = []
    web_searches: list[str] = []
    turn_failed_errors: list[str] = []

    for line_number, line in enumerate(
        args.stream.read_text(encoding="utf-8", errors="replace").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_type = str(event.get("type", "unknown"))
        event_counts[event_type] = event_counts.get(event_type, 0) + 1

        if event_type == "turn.failed":
            error = event.get("error")
            if isinstance(error, dict) and error.get("message"):
                turn_failed_errors.append(str(error["message"]))
            elif error:
                turn_failed_errors.append(str(error))

        item = event.get("item")
        if not isinstance(item, dict):
            continue
        kind = item_kind(item)
        if kind:
            item_counts[kind] = item_counts.get(kind, 0) + 1
        if event_type != "item.completed":
            continue
        completed_items.append(
            {
                "line": line_number,
                "id": item.get("id"),
                "type": kind,
                "focus": item_focus(item),
            }
        )
        if kind == "agent_message" and isinstance(item.get("text"), str):
            agent_messages.append(item["text"])
        if kind == "web_search" and item.get("query"):
            web_searches.append(str(item["query"]))

    chat_text = ""
    if args.last_message and args.last_message.is_file():
        chat_text = args.last_message.read_text(encoding="utf-8", errors="replace").strip()
    if not chat_text:
        chat_text = "\n\n".join(text.strip() for text in agent_messages if text.strip())
    args.chat_out.write_text(chat_text + ("\n" if chat_text else ""), encoding="utf-8")

    summary = {
        "stream": str(args.stream),
        "chat": str(args.chat_out),
        "last_message": str(args.last_message) if args.last_message else "",
        "event_counts": event_counts,
        "item_counts": item_counts,
        "completed_items": completed_items,
        "web_searches": web_searches,
        "turn_failed_errors": turn_failed_errors,
        "final_chat_chars": len(chat_text),
    }
    args.summary_out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
