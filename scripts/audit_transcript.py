#!/usr/bin/env python3
"""Scan Claude output/transcript files for evaluation-artifact leakage."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


FORBIDDEN_RE = re.compile(
    r"("
    r"DRAGUN|TREC|human_rubrics|human_assessments|official_evaluation_results|"
    r"auto_report_assessments|AutoJudge|auto_judge|trec-dragun/resources|"
    r"trec34/dragun/data|MS MARCO|msmarco_v2\.1_doc_|answer key|answer-key"
    r")",
    re.IGNORECASE,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--topic-id")
    parser.add_argument("--summary-out", type=Path)
    args = parser.parse_args()

    text = args.raw.read_text(encoding="utf-8", errors="replace")
    issues: list[dict[str, str]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if FORBIDDEN_RE.search(line):
            issues.append(
                {
                    "line": str(line_number),
                    "message": "forbidden evaluation-artifact term appears in Claude output",
                }
            )
        if args.topic_id and args.topic_id in line:
            issues.append(
                {
                    "line": str(line_number),
                    "message": "hidden topic ID appears in Claude output",
                }
            )

    summary = {"valid": not issues, "issues": issues}
    if args.summary_out:
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        args.summary_out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        print(json.dumps(summary, indent=2, sort_keys=True))

    if issues:
        for issue in issues:
            print(f"{args.raw}:{issue['line']}: {issue['message']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
