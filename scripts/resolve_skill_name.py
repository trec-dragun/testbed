#!/usr/bin/env python3
"""Resolve the first skill name in a portable skill repo."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def skill_name(skill_file: Path) -> str:
    text = skill_file.read_text(encoding="utf-8")
    match = re.search(r"(?ms)\A---\s*\n(?P<header>.*?)\n---\s*\n", text)
    if not match:
        return skill_file.parent.name
    for line in match.group("header").splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() == "name":
            return value.strip().strip("\"'")
    return skill_file.parent.name


def resolve(repo: Path) -> str:
    skill_files = sorted((repo / "skills").glob("*/SKILL.md"))
    if not skill_files:
        raise SystemExit(f"no skills/*/SKILL.md found in {repo}")
    return skill_name(skill_files[0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill", required=True, type=Path)
    args = parser.parse_args()
    print(resolve(args.skill.resolve()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
