#!/usr/bin/env python3
"""Collect the report files produced by a skill run."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def latest_report(search_dir: Path) -> Path:
    candidates = sorted(
        search_dir.glob("reports/**/report.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise SystemExit(f"no reports/**/report.json found under {search_dir}")
    return candidates[0]


def copy_report_dir(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--search-dir", required=True, type=Path)
    parser.add_argument("--topic-dir", required=True, type=Path)
    parser.add_argument("--public-dir", type=Path)
    parser.add_argument("--summary-out", type=Path)
    args = parser.parse_args()

    report_json = latest_report(args.search_dir)
    report_dir = report_json.parent

    topic_report_dir = args.topic_dir / "skill_report"
    copy_report_dir(report_dir, topic_report_dir)

    public_report_json = None
    if args.public_dir:
        copy_report_dir(report_dir, args.public_dir)
        public_report_json = args.public_dir / "report.json"

    summary = {
        "source_report_dir": str(report_dir),
        "topic_report_dir": str(topic_report_dir),
        "topic_report_json": str(topic_report_dir / "report.json"),
        "topic_report_html": str(topic_report_dir / "report.html"),
        "public_report_dir": str(args.public_dir) if args.public_dir else "",
        "public_report_json": str(public_report_json) if public_report_json else "",
        "public_report_html": str(args.public_dir / "report.html") if args.public_dir else "",
    }

    if args.summary_out:
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        args.summary_out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(summary["topic_report_json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
