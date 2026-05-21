#!/usr/bin/env python3
"""List topic IDs from a topics JSONL file."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def iter_topics(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            topic_id = record.get("docid") or record.get("topic_id")
            if not topic_id:
                raise SystemExit(f"{path}:{line_number}: missing docid/topic_id")
            yield str(topic_id), record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topics", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=0, help="Optional maximum topic count")
    parser.add_argument("--json", action="store_true", help="Print JSON objects instead of IDs")
    args = parser.parse_args()

    count = 0
    for topic_id, record in iter_topics(args.topics):
        if args.json:
            print(json.dumps({"topic_id": topic_id, "title": record.get("title", "")}, ensure_ascii=False))
        else:
            print(topic_id)
        count += 1
        if args.limit and count >= args.limit:
            break

    if count == 0:
        print(f"no topics found in {args.topics}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
