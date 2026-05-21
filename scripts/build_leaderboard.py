#!/usr/bin/env python3
"""Update leaderboard CSV/JSON from a completed run."""

from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
FIELDS = [
    "rank",
    "run_id",
    "model",
    "provider",
    "skill",
    "skill_commit",
    "date",
    "auto_supportive_score",
    "auto_contradictory_score",
    "valid_topics",
    "total_topics",
    "invalid_topics",
    "citation_url_pass_rate",
    "forbidden_source_violations",
    "reports_dir",
]


def safe_name(value: str) -> str:
    import re

    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value)
    return cleaned.strip("._-") or "run"


def load_manifest(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "manifest.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def load_score(run_dir: Path, run_id: str) -> tuple[str, str]:
    path = run_dir / "autojudge" / "auto_report_generation_per_run_results.csv"
    if not path.exists():
        return "", ""
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("run_tag") == run_id:
                return row.get("supportive_score", ""), row.get("contradictory_score", "")
    return "", ""


def validation_stats(run_dir: Path) -> dict[str, Any]:
    summaries = sorted((run_dir / "topics").glob("*/validation.json"))
    total = len(summaries)
    valid = 0
    citation_rates = []
    forbidden = 0
    for path in summaries:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("valid"):
            valid += 1
        citation_rates.append(float(data.get("citation_url_pass_rate", 1.0)))
        forbidden += int(data.get("forbidden_source_violations", 0))
    return {
        "valid_topics": valid,
        "total_topics": total,
        "invalid_topics": total - valid,
        "citation_url_pass_rate": sum(citation_rates) / total if total else "",
        "forbidden_source_violations": forbidden,
    }


def read_existing(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def sort_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    def key(row: dict[str, Any]) -> tuple[float, float]:
        try:
            support = float(row.get("auto_supportive_score") or -1)
        except ValueError:
            support = -1
        try:
            contra = float(row.get("auto_contradictory_score") or 999)
        except ValueError:
            contra = 999
        return (-support, contra)

    sorted_rows = sorted(rows, key=key)
    for index, row in enumerate(sorted_rows, start=1):
        row["rank"] = str(index)
    return sorted_rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--leaderboard-dir", type=Path, default=ROOT / "leaderboard")
    args = parser.parse_args()

    run_safe = safe_name(args.run_id)
    run_dir = ROOT / "runs" / run_safe
    manifest = load_manifest(run_dir)
    supportive, contradictory = load_score(run_dir, args.run_id)
    stats = validation_stats(run_dir)

    row = {
        "rank": "",
        "run_id": args.run_id,
        "model": manifest.get("model", ""),
        "provider": manifest.get("provider", ""),
        "skill": manifest.get("skill", ""),
        "skill_commit": manifest.get("skill_commit", ""),
        "date": datetime.now(timezone.utc).date().isoformat(),
        "auto_supportive_score": supportive,
        "auto_contradictory_score": contradictory,
        "reports_dir": manifest.get("reports_dir", str(ROOT / "reports" / run_safe)),
        **stats,
    }

    args.leaderboard_dir.mkdir(parents=True, exist_ok=True)
    csv_path = args.leaderboard_dir / "leaderboard.csv"
    rows = [existing for existing in read_existing(csv_path) if existing.get("run_id") != args.run_id]
    rows.append({field: row.get(field, "") for field in FIELDS})
    rows = sort_rows(rows)

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    json_path = args.leaderboard_dir / "leaderboard.json"
    json_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"updated {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
