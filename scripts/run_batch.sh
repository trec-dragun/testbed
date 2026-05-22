#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOPICS="$ROOT_DIR/data/trec-2025-dragun-topics.jsonl"
SKILL="$ROOT_DIR/skills_under_test/lateral-reading-skill"
MODEL="${MODEL:-sonnet}"
PROVIDER="${PROVIDER:-anthropic}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
RUN_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-}"
RUN_ID="${RUN_ID:-}"
LIMIT=0
OVERWRITE=0

format_duration() {
  local seconds="$1"
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))
  printf '%02d:%02d:%02d' "$hours" "$minutes" "$secs"
}

usage() {
  cat <<'EOF'
usage: scripts/run_batch.sh [options]

Options:
  --topics PATH          topics JSONL
  --skill PATH           Skill repo to test
  --model MODEL          Claude Code model or OpenRouter model name
  --provider NAME        anthropic or openrouter
  --effort EFFORT        Claude Code reasoning effort (default: high)
  --run-id ID            Output run ID
  --limit N              Run only the first N topics
  --overwrite            Replace existing run output
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topics) TOPICS="$2"; shift 2 ;;
    --skill) SKILL="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${PROVIDER}_${MODEL}_$(basename "$SKILL")")"
fi
RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
if [[ -z "$RUN_PERMISSION_MODE" ]]; then
  if [[ "$PROVIDER" == "openrouter" ]]; then
    RUN_PERMISSION_MODE="default"
  else
    RUN_PERMISSION_MODE="auto"
  fi
fi
export CLAUDE_PERMISSION_MODE="$RUN_PERMISSION_MODE"
RUN_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
RUN_DIR="$ROOT_DIR/runs/$RUN_SAFE"
RUN_JSONL="$RUN_DIR/dragun_task2.jsonl"

if [[ "$OVERWRITE" == "1" ]]; then
  rm -rf "$RUN_DIR"
  rm -rf "$ROOT_DIR/reports/$RUN_SAFE"
fi
if [[ -e "$RUN_JSONL" ]]; then
  echo "error: $RUN_JSONL already exists; use --overwrite to replace it" >&2
  exit 2
fi
mkdir -p "$RUN_DIR"

if [[ "$PROVIDER" == "openrouter" && "${OPENROUTER_PREFLIGHT:-1}" == "1" ]]; then
  "$ROOT_DIR/scripts/check_openrouter_key.sh"
fi

python3 "$ROOT_DIR/scripts/audit_session_exposure.py" --skill "$SKILL"
SKILL_FILE="$(python3 "$ROOT_DIR/scripts/resolve_skill_file.py" --skill "$SKILL")"
SKILL_COMMIT=""
if [[ -d "$SKILL/.git" ]] && git -C "$SKILL" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SKILL_COMMIT="$(git -C "$SKILL" rev-parse --short HEAD)"
fi

TOPIC_LIST="$RUN_DIR/topics.txt"
python3 "$ROOT_DIR/scripts/list_topics.py" --topics "$TOPICS" --limit "$LIMIT" > "$TOPIC_LIST"

TOTAL="$(wc -l < "$TOPIC_LIST" | tr -d ' ')"
CURRENT=0
START_TS="$(date +%s)"
while IFS= read -r TOPIC_ID; do
  CURRENT=$((CURRENT + 1))
  ARTICLE_START_TS="$(date +%s)"
  ELAPSED=$((ARTICLE_START_TS - START_TS))
  if [[ "$CURRENT" -gt 1 ]]; then
    COMPLETED=$((CURRENT - 1))
    AVG=$((ELAPSED / COMPLETED))
    REMAINING=$((TOTAL - CURRENT + 1))
    ETA="$((AVG * REMAINING))"
    ETA_TEXT="$(format_duration "$ETA")"
  else
    ETA_TEXT="estimating"
  fi
  echo "[$CURRENT/$TOTAL] start $TOPIC_ID | elapsed $(format_duration "$ELAPSED") | eta $ETA_TEXT"
  "$ROOT_DIR/scripts/run_one.sh" \
    --topics "$TOPICS" \
    --topic-id "$TOPIC_ID" \
    --skill "$SKILL" \
    --model "$MODEL" \
    --provider "$PROVIDER" \
    --effort "$CLAUDE_REASONING_EFFORT" \
    --run-id "$RUN_ID" \
    --run-jsonl "$RUN_JSONL"
  ARTICLE_END_TS="$(date +%s)"
  ARTICLE_SECONDS=$((ARTICLE_END_TS - ARTICLE_START_TS))
  ELAPSED=$((ARTICLE_END_TS - START_TS))
  COMPLETED="$CURRENT"
  AVG=$((ELAPSED / COMPLETED))
  REMAINING=$((TOTAL - CURRENT))
  ETA=$((AVG * REMAINING))
  echo "[$CURRENT/$TOTAL] done  $TOPIC_ID | article $(format_duration "$ARTICLE_SECONDS") | elapsed $(format_duration "$ELAPSED") | eta $(format_duration "$ETA")"
done < "$TOPIC_LIST"

mkdir -p "$ROOT_DIR/data/runs/report_generation_runs"
cp "$RUN_JSONL" "$ROOT_DIR/data/runs/report_generation_runs/$RUN_ID"

cat > "$RUN_DIR/manifest.json" <<EOF
{
  "run_id": "$RUN_ID",
  "model": "$MODEL",
  "provider": "$PROVIDER",
  "claude_reasoning_effort": "$CLAUDE_REASONING_EFFORT",
  "claude_permission_mode": "$RUN_PERMISSION_MODE",
  "skill": "$SKILL",
  "skill_commit": "$SKILL_COMMIT",
  "skill_file": "$SKILL_FILE",
  "topics": "$TOPICS",
  "run_jsonl": "$RUN_JSONL",
  "reports_dir": "$ROOT_DIR/reports/$RUN_SAFE",
  "topic_id_hidden_from_model": true,
  "claude_no_session_persistence": true,
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "run jsonl: $RUN_JSONL"
echo "autojudge input: $ROOT_DIR/data/runs/report_generation_runs/$RUN_ID"
echo "skill reports: $ROOT_DIR/reports/$RUN_SAFE"
