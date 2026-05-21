#!/usr/bin/env python3
"""Resolve the slash command for the first Claude Code skill in a cloned skill repo."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*", re.DOTALL)


def parse_frontmatter_name(path: Path) -> str | None:
    text = path.read_text(encoding="utf-8", errors="replace")
    match = FRONTMATTER_RE.match(text)
    if not match:
        return None
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() == "name":
            return value.strip().strip("\"'")
    return None


def plugin_name(repo: Path) -> str | None:
    manifest = repo / ".claude-plugin" / "plugin.json"
    if not manifest.exists():
        return None
    data = json.loads(manifest.read_text(encoding="utf-8"))
    name = data.get("name")
    return str(name) if name else None


def resolve(repo: Path) -> str:
    skill_files = sorted((repo / "skills").glob("*/SKILL.md"))
    if not skill_files:
        raise SystemExit(f"no skills/*/SKILL.md found in {repo}")
    skill_name = parse_frontmatter_name(skill_files[0]) or skill_files[0].parent.name
    plug = plugin_name(repo)
    if plug:
        return f"/{plug}:{skill_name}"
    return f"/{skill_name}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill", required=True, type=Path)
    args = parser.parse_args()
    print(resolve(args.skill.resolve()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
