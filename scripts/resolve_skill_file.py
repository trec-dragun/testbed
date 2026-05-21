#!/usr/bin/env python3
"""Resolve the first Claude Code skill file in a cloned skill repo."""

from __future__ import annotations

import argparse
from pathlib import Path


def resolve(repo: Path) -> Path:
    skill_files = sorted((repo / "skills").glob("*/SKILL.md"))
    if not skill_files:
        raise SystemExit(f"no skills/*/SKILL.md found in {repo}")
    return skill_files[0].resolve()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill", required=True, type=Path)
    args = parser.parse_args()
    print(resolve(args.skill.resolve()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
