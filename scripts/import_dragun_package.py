#!/usr/bin/env python3
"""Import files from the official DRAGUN package into the local data layout."""

from __future__ import annotations

import argparse
import shutil
import zipfile
from pathlib import Path


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_tree_contents(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)


def find_one(root: Path, name: str) -> Path | None:
    matches = sorted(root.rglob(name))
    return matches[0] if matches else None


def find_dir(root: Path, name: str) -> Path | None:
    matches = sorted(path for path in root.rglob(name) if path.is_dir())
    return matches[0] if matches else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--work", type=Path, default=Path("tmp/dragun_package_extract"))
    args = parser.parse_args()

    if args.work.exists():
        shutil.rmtree(args.work)
    args.work.mkdir(parents=True)
    with zipfile.ZipFile(args.zip) as archive:
        archive.extractall(args.work)

    imported: list[str] = []

    topics = find_one(args.work, "trec-2025-dragun-topics.jsonl")
    if topics:
        copy_file(topics, args.out / "trec-2025-dragun-topics.jsonl")
        imported.append("topics")

    for dirname in ("human_rubrics", "human_assessments", "official_evaluation_results"):
        source = find_dir(args.work, dirname)
        if source:
            copy_tree_contents(source, args.out / dirname)
            imported.append(dirname)

    runs = find_dir(args.work, "runs")
    if runs:
        copy_tree_contents(runs, args.out / "runs")
        imported.append("runs")

    if not imported:
        raise SystemExit(f"no known DRAGUN files found in {args.zip}")

    print("imported: " + ", ".join(imported))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
