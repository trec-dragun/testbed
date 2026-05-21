#!/usr/bin/env python3
"""Make a string safe for run IDs and file names."""

from __future__ import annotations

import argparse
import re


def sanitize(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    cleaned = re.sub(r"_+", "_", cleaned).strip("._-")
    return cleaned or "run"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("value")
    args = parser.parse_args()
    print(sanitize(args.value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
