#!/usr/bin/env python3
"""Write one article as plaintext without exposing its topic ID."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


TITLE_KEYS = ("title", "headline")
URL_KEYS = ("url", "source_url")
HEADING_KEYS = ("heading", "headings")
CONTENT_KEYS = ("body", "text", "content", "article_text", "cleaned_text", "main_content", "paragraphs")


def load_topic(path: Path, topic_id: str) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            record = json.loads(line)
            current_id = record.get("docid") or record.get("topic_id")
            if current_id == topic_id:
                return record
    raise SystemExit(f"topic not found: {topic_id}")


def first_value(record: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for key in keys:
        value = record.get(key)
        if value:
            return value
    return ""


def format_value(value: Any) -> str:
    if isinstance(value, list):
        return "\n".join(str(item) for item in value if str(item).strip())
    return str(value).strip()


def plain_text(record: dict[str, Any]) -> str:
    lines: list[str] = []
    title = first_value(record, TITLE_KEYS)
    if title:
        lines.append(f"Title: {format_value(title)}")
    url = first_value(record, URL_KEYS)
    if url:
        lines.append(f"URL: {format_value(url)}")
    heading = first_value(record, HEADING_KEYS)
    if heading:
        label = "Headings" if isinstance(heading, list) else "Heading"
        lines.append(f"{label}: {format_value(heading)}")
    body = first_value(record, CONTENT_KEYS)
    if body:
        if lines:
            lines.append("")
        lines.append(format_value(body))
    if not body:
        raise SystemExit("could not identify article text in topic record")
    return "\n".join(lines).strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topics", required=True, type=Path)
    parser.add_argument("--topic-id", required=True)
    parser.add_argument("--out-text", required=True, type=Path)
    args = parser.parse_args()

    record = load_topic(args.topics, args.topic_id)
    args.out_text.parent.mkdir(parents=True, exist_ok=True)
    args.out_text.write_text(plain_text(record), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
