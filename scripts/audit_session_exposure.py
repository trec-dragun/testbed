#!/usr/bin/env python3
"""Audit strings and permissions that are visible to each generation session."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_VISIBLE_RE = re.compile(
    r"\b(DRAGUN|TREC|AutoJudge|MS MARCO|human_assessments|human_rubrics|"
    r"official_evaluation_results|msmarco_v2\.1_doc|topic_id|docid)\b",
    re.IGNORECASE,
)
FORBIDDEN_RUN_ONE_SNIPPETS = [
    "dragun-skill-session",
    "Bash(curl *)",
    "Bash(python3 *)",
    "Bash(python *)",
    "--json-schema",
    "/lateral-reading-skill:lateral-reading",
    "--debug-file \"$CLAUDE_DEBUG_FILE\"",
]


def scan_run_one() -> list[str]:
    issues: list[str] = []
    path = ROOT / "scripts" / "run_one.sh"
    text = path.read_text(encoding="utf-8")
    for snippet in FORBIDDEN_RUN_ONE_SNIPPETS:
        if snippet in text:
            issues.append(f"{path}: forbidden session exposure or broad tool permission: {snippet}")
    return issues


def scan_skill(path: Path) -> list[str]:
    issues: list[str] = []
    if not path.exists():
        return [f"{path}: skill path does not exist"]
    for file_path in sorted(path.rglob("*")):
        if not file_path.is_file() or ".git" in file_path.parts:
            continue
        try:
            text = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            if FORBIDDEN_VISIBLE_RE.search(line):
                issues.append(f"{file_path}:{line_number}: skill contains evaluation-specific term: {line.strip()}")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill", type=Path, help="Optionally scan a skill repo before testing it")
    args = parser.parse_args()

    issues: list[str] = []
    issues.extend(scan_run_one())
    if args.skill:
        issues.extend(scan_skill(args.skill))

    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        return 1
    print("session exposure audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
