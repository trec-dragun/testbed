#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${1:?usage: scripts/clone_skill.sh <git-url> [destination-name]}"
NAME="${2:-$(basename "$URL" .git)}"
DEST="$ROOT_DIR/skills_under_test/$NAME"

mkdir -p "$ROOT_DIR/skills_under_test"
if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" pull --ff-only
else
  git clone --depth 1 "$URL" "$DEST"
fi

echo "$DEST"
