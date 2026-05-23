#!/usr/bin/env python3
"""Collect the report files produced by a skill run."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path


def latest_report(search_dir: Path) -> Path | None:
    candidates = sorted(
        search_dir.glob("reports/**/report.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def copy_report_dir(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def render_report(
    *,
    report_dir: Path,
    target_text: Path | None,
    render_script: Path | None,
) -> None:
    target_path = report_dir / "target.txt"
    report_json = report_dir / "report.json"
    report_html = report_dir / "report.html"

    if not target_path.exists():
        if target_text and target_text.exists():
            shutil.copy2(target_text, target_path)
        else:
            target_path.write_text("", encoding="utf-8")

    if report_html.exists():
        return

    if render_script and render_script.is_file():
        subprocess.run(
            [
                "python3",
                str(render_script),
                "--input",
                str(target_path),
                "--report",
                str(report_json),
                "--out",
                str(report_html),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        return

    report = json.loads(report_json.read_text(encoding="utf-8"))
    report_html.write_text(
        "<!doctype html><meta charset=\"utf-8\"><title>Report</title>"
        "<pre id=\"report\"></pre><script>"
        f"document.getElementById('report').textContent = {json.dumps(json.dumps(report, ensure_ascii=False, indent=2))};"
        "</script>\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--search-dir", required=True, type=Path)
    parser.add_argument("--topic-dir", required=True, type=Path)
    parser.add_argument("--public-dir", type=Path)
    parser.add_argument("--target-text", type=Path)
    parser.add_argument("--render-script", type=Path)
    parser.add_argument("--summary-out", type=Path)
    args = parser.parse_args()

    report_json = latest_report(args.search_dir)
    if not report_json:
        raise SystemExit(f"no reports/**/report.json found under {args.search_dir}")

    source_report_dir = report_json.parent
    topic_report_dir = args.topic_dir / "skill_report"

    render_report(
        report_dir=source_report_dir,
        target_text=args.target_text,
        render_script=args.render_script,
    )
    copy_report_dir(source_report_dir, topic_report_dir)

    public_report_json = None
    if args.public_dir:
        copy_report_dir(source_report_dir, args.public_dir)
        public_report_json = args.public_dir / "report.json"

    summary = {
        "source_report_dir": str(source_report_dir),
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
