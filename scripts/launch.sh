#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKILL_REPO="${SKILL_REPO:-https://github.com/trec-dragun/lateral-reading-skill.git}"
SKILL_PATH=""
SKILL_COMMAND="${SKILL_COMMAND:-}"
MODEL="${MODEL:-sonnet}"
PROVIDER="${PROVIDER:-anthropic}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
RUN_ID="${RUN_ID:-}"
BOOTSTRAP=1
OVERWRITE=0
LIMIT=0
SCORE=0

usage() {
  cat <<'EOF'
usage: scripts/launch.sh [options]

One-command path for setup plus running all DRAGUN articles.

Options:
  --skill-repo URL       Git repo for the skill under test
  --skill PATH           Existing local skill repo
  --skill-command CMD    Slash command to invoke, e.g. /plugin:skill
  --model MODEL          Claude Code model or OpenRouter model name
  --provider NAME        anthropic or openrouter
  --effort EFFORT        Claude Code reasoning effort (default: high)
  --run-id ID            Output run ID
  --limit N              Run only the first N topics
  --overwrite            Replace existing run output
  --no-bootstrap         Skip dependency/data bootstrap
  --score                Run AutoJudge after generation
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-repo) SKILL_REPO="$2"; shift 2 ;;
    --skill) SKILL_PATH="$2"; shift 2 ;;
    --skill-command) SKILL_COMMAND="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
    --no-bootstrap) BOOTSTRAP=0; shift ;;
    --score) SCORE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$BOOTSTRAP" == "1" ]]; then
  "$ROOT_DIR/scripts/bootstrap.sh"
fi

if [[ -z "$SKILL_PATH" ]]; then
  SKILL_PATH="$("$ROOT_DIR/scripts/clone_skill.sh" "$SKILL_REPO")"
fi

BATCH_ARGS=(
  --skill "$SKILL_PATH"
  --model "$MODEL"
  --provider "$PROVIDER"
  --effort "$CLAUDE_REASONING_EFFORT"
  --limit "$LIMIT"
)
if [[ -n "$SKILL_COMMAND" ]]; then
  BATCH_ARGS+=(--skill-command "$SKILL_COMMAND")
fi
if [[ -n "$RUN_ID" ]]; then
  BATCH_ARGS+=(--run-id "$RUN_ID")
fi
if [[ "$OVERWRITE" == "1" ]]; then
  BATCH_ARGS+=(--overwrite)
fi

"$ROOT_DIR/scripts/run_batch.sh" "${BATCH_ARGS[@]}"

if [[ "$SCORE" == "1" ]]; then
  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${PROVIDER}_${MODEL}_$(basename "$SKILL_PATH")")"
  fi
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
  "$ROOT_DIR/scripts/score_with_autojudge.sh" --run-id "$RUN_ID"
fi
