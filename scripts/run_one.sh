#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOPICS="$ROOT_DIR/data/trec-2025-dragun-topics.jsonl"
TOPIC_ID=""
TOPIC_ID_FILE=""
TOPIC_ALIAS=""
SKILL="$ROOT_DIR/skills_under_test/lateral-reading-skill"
SKILL_COMMAND="${SKILL_COMMAND:-}"
MODEL="${MODEL:-sonnet}"
PROVIDER="${PROVIDER:-anthropic}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
CLAUDE_TOOLS_DEFAULT="${CLAUDE_TOOLS:-WebFetch,WebSearch,Read,Write}"
RUN_ID="${RUN_ID:-}"
RUN_JSONL=""
MAX_BUDGET_USD="${MAX_BUDGET_USD:-5.00}"
KEEP_SESSION_DIR="${KEEP_SESSION_DIR:-0}"
OVERWRITE_TOPIC="${OVERWRITE_TOPIC:-0}"
OPENROUTER_SERVICE_TIER="${OPENROUTER_SERVICE_TIER:-auto}"
OPENROUTER_PROXY_PID=""

usage() {
  cat <<'EOF'
usage: scripts/run_one.sh --topic-id ID [options]

Options:
  --topics PATH          topics JSONL
  --skill PATH           Skill repo to test
  --skill-command CMD    Slash command to invoke, e.g. /plugin:skill
  --topic-alias NAME     Anonymous artifact folder name for this topic
  --topic-id-file PATH   Read the topic ID from a private file instead of argv
  --model MODEL          Claude Code model or OpenRouter model name
  --provider NAME        anthropic or openrouter
  --effort EFFORT        Claude Code reasoning effort (default: high)
  --run-id ID            Output run ID
  --run-jsonl PATH       aggregate evaluation JSONL path to append
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topics) TOPICS="$2"; shift 2 ;;
    --topic-id) TOPIC_ID="$2"; shift 2 ;;
    --topic-id-file) TOPIC_ID_FILE="$2"; shift 2 ;;
    --topic-alias) TOPIC_ALIAS="$2"; shift 2 ;;
    --skill) SKILL="$2"; shift 2 ;;
    --skill-command) SKILL_COMMAND="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --run-jsonl) RUN_JSONL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$TOPIC_ID" && -n "$TOPIC_ID_FILE" ]]; then
  TOPIC_ID="$(<"$TOPIC_ID_FILE")"
fi
if [[ -z "$TOPIC_ID" ]]; then
  echo "error: --topic-id is required" >&2
  exit 2
fi
if [[ -z "$SKILL_COMMAND" ]]; then
  SKILL_COMMAND="$(python3 "$ROOT_DIR/scripts/resolve_skill_command.py" --skill "$SKILL")"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${PROVIDER}_${MODEL}_$(basename "$SKILL")")"
fi
RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
RUN_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"

if [[ -z "$TOPIC_ALIAS" ]]; then
  TOPIC_ALIAS="$(python3 -c 'import hashlib, sys; print("topic_" + hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$TOPIC_ID")"
fi
TOPIC_ARTIFACT_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$TOPIC_ALIAS")"
RUN_DIR="$ROOT_DIR/runs/$RUN_SAFE"
TOPIC_DIR="$RUN_DIR/topics/$TOPIC_ARTIFACT_SAFE"
if [[ -z "$RUN_JSONL" ]]; then
  RUN_JSONL="$RUN_DIR/dragun_task2.jsonl"
fi

CLAUDE_STDOUT="$TOPIC_DIR/claude_raw.txt"
CLAUDE_STDERR="$TOPIC_DIR/claude_stderr.log"
CLAUDE_EXIT_CODE="$TOPIC_DIR/claude_exit_code.txt"
CLAUDE_DEBUG_FILE="$TOPIC_DIR/claude_debug.log"

if [[ "$OVERWRITE_TOPIC" == "1" && -d "$TOPIC_DIR" ]]; then
  rm -rf "$TOPIC_DIR"
fi
mkdir -p "$TOPIC_DIR"

print_claude_diagnostics() {
  echo "claude stdout tail: $CLAUDE_STDOUT" >&2
  if [[ -s "$CLAUDE_STDOUT" ]]; then
    tail -n 80 "$CLAUDE_STDOUT" >&2 || true
  else
    echo "(empty)" >&2
  fi
  echo "claude stderr tail: $CLAUDE_STDERR" >&2
  if [[ -s "$CLAUDE_STDERR" ]]; then
    tail -n 120 "$CLAUDE_STDERR" >&2 || true
  else
    echo "(empty)" >&2
  fi
  if [[ -s "$CLAUDE_DEBUG_FILE" ]]; then
    echo "claude debug tail: $CLAUDE_DEBUG_FILE" >&2
    tail -n 120 "$CLAUDE_DEBUG_FILE" >&2 || true
  fi
}

SESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/news-skill-session.XXXXXX")"
SESSION_WORK_DIR="$SESSION_DIR/work"
SESSION_PROMPT="$SESSION_DIR/prompt.txt"
SESSION_CLAUDE_DEBUG_FILE="$SESSION_DIR/claude_debug.log"

cleanup() {
  if [[ -n "$OPENROUTER_PROXY_PID" ]]; then
    kill "$OPENROUTER_PROXY_PID" 2>/dev/null || true
    wait "$OPENROUTER_PROXY_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP_SESSION_DIR" != "1" ]]; then
    chmod -R u+w "$SESSION_DIR" 2>/dev/null || true
    rm -rf "$SESSION_DIR"
  else
    echo "kept session dir: $SESSION_DIR" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$SESSION_WORK_DIR/reports"
python3 "$ROOT_DIR/scripts/make_article_input.py" \
  --topics "$TOPICS" \
  --topic-id "$TOPIC_ID" \
  --out-text "$TOPIC_DIR/input.txt"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude .git "$SKILL"/ "$SESSION_WORK_DIR"/
else
  cp -R "$SKILL"/. "$SESSION_WORK_DIR"/
  rm -rf "$SESSION_WORK_DIR/.git"
fi

RENDER_SCRIPT="$(find "$SESSION_WORK_DIR" -path "*/scripts/render_report_html.py" -type f -print -quit)"

{
  printf '%s\n\n' "$SKILL_COMMAND"
  cat "$TOPIC_DIR/input.txt"
} > "$SESSION_PROMPT"

CLAUDE_ARGS=(
  --print
  --input-format text
  --plugin-dir "$SESSION_WORK_DIR"
  --no-session-persistence
  --permission-mode "$PERMISSION_MODE"
  --max-budget-usd "$MAX_BUDGET_USD"
  --model "$MODEL"
  --effort "$CLAUDE_REASONING_EFFORT"
  --tools "$CLAUDE_TOOLS_DEFAULT"
  --allowed-tools "$CLAUDE_TOOLS_DEFAULT"
)
if [[ "${CLAUDE_DEBUG_LOG:-0}" == "1" ]]; then
  CLAUDE_ARGS+=(--debug-file "$SESSION_CLAUDE_DEBUG_FILE")
fi

export CLAUDE_CODE_EFFORT_LEVEL="$CLAUDE_REASONING_EFFORT"
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1

if [[ "${CLAUDE_BARE:-0}" == "1" ]]; then
  CLAUDE_ARGS=(--bare "${CLAUDE_ARGS[@]}")
else
  CLAUDE_ARGS+=(--setting-sources project)
fi

if [[ "$PROVIDER" == "openrouter" ]]; then
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "error: OPENROUTER_API_KEY is required for --provider openrouter" >&2
    exit 2
  fi
  OPENROUTER_UPSTREAM_BASE_URL="${ANTHROPIC_BASE_URL:-https://openrouter.ai/api}"
  OPENROUTER_EFFECTIVE_SERVICE_TIER="$OPENROUTER_SERVICE_TIER"
  if [[ "$OPENROUTER_EFFECTIVE_SERVICE_TIER" == "auto" ]]; then
    case "$MODEL" in
      openai/*|google/*) OPENROUTER_EFFECTIVE_SERVICE_TIER="flex" ;;
      *) OPENROUTER_EFFECTIVE_SERVICE_TIER="" ;;
    esac
  fi
  if [[ "$OPENROUTER_EFFECTIVE_SERVICE_TIER" != "off" && "$OPENROUTER_EFFECTIVE_SERVICE_TIER" != "none" && -n "$OPENROUTER_EFFECTIVE_SERVICE_TIER" ]]; then
    OPENROUTER_PROXY_PORT_FILE="$SESSION_DIR/openrouter_proxy.port"
    OPENROUTER_PROXY_LOG="$TOPIC_DIR/openrouter_proxy.log"
    python3 "$ROOT_DIR/scripts/openrouter_service_tier_proxy.py" \
      --base-url "$OPENROUTER_UPSTREAM_BASE_URL" \
      --service-tier "$OPENROUTER_EFFECTIVE_SERVICE_TIER" \
      --port-file "$OPENROUTER_PROXY_PORT_FILE" \
      >"$OPENROUTER_PROXY_LOG" 2>&1 &
    OPENROUTER_PROXY_PID=$!
    for _ in {1..50}; do
      if [[ -s "$OPENROUTER_PROXY_PORT_FILE" ]]; then
        break
      fi
      sleep 0.1
    done
    if [[ ! -s "$OPENROUTER_PROXY_PORT_FILE" ]]; then
      echo "error: OpenRouter service-tier proxy did not start" >&2
      cat "$OPENROUTER_PROXY_LOG" >&2 || true
      exit 1
    fi
    OPENROUTER_PROXY_PORT="$(<"$OPENROUTER_PROXY_PORT_FILE")"
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${OPENROUTER_PROXY_PORT}/api"
  else
    export ANTHROPIC_BASE_URL="$OPENROUTER_UPSTREAM_BASE_URL"
  fi
  export ANTHROPIC_API_KEY=""
  export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
  OPENROUTER_AUTH_HEADER="Authorization: Bearer $OPENROUTER_API_KEY"
  if [[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ]]; then
    export ANTHROPIC_CUSTOM_HEADERS="${OPENROUTER_AUTH_HEADER}"$'\n'"${ANTHROPIC_CUSTOM_HEADERS}"
  else
    export ANTHROPIC_CUSTOM_HEADERS="$OPENROUTER_AUTH_HEADER"
  fi
  export ANTHROPIC_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
  export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
elif [[ "$PROVIDER" != "anthropic" ]]; then
  echo "error: unsupported provider: $PROVIDER" >&2
  exit 2
fi

: > "$CLAUDE_STDOUT"
: > "$CLAUDE_STDERR"
set +e
(
  cd "$SESSION_WORK_DIR"
  claude "${CLAUDE_ARGS[@]}" < "$SESSION_PROMPT"
) > "$CLAUDE_STDOUT" 2>"$CLAUDE_STDERR"
CLAUDE_STATUS=$?
set -e

if [[ -s "$SESSION_CLAUDE_DEBUG_FILE" ]]; then
  cp "$SESSION_CLAUDE_DEBUG_FILE" "$CLAUDE_DEBUG_FILE"
fi
printf '%s\n' "$CLAUDE_STATUS" > "$CLAUDE_EXIT_CODE"
if [[ "$CLAUDE_STATUS" -ne 0 ]]; then
  KEEP_SESSION_DIR=1
  echo "error: claude exited with status $CLAUDE_STATUS" >&2
  echo "kept failed session dir: $SESSION_DIR" >&2
  print_claude_diagnostics
  exit "$CLAUDE_STATUS"
fi

if ! python3 "$ROOT_DIR/scripts/audit_transcript.py" \
  --raw "$CLAUDE_STDOUT" \
  --topic-id "$TOPIC_ID" \
  --summary-out "$TOPIC_DIR/transcript_audit.json"; then
  KEEP_SESSION_DIR=1
  echo "error: claude output exposed a hidden evaluation artifact" >&2
  echo "kept failed session dir: $SESSION_DIR" >&2
  print_claude_diagnostics
  exit 1
fi
if [[ -s "$CLAUDE_DEBUG_FILE" ]]; then
  if ! python3 "$ROOT_DIR/scripts/audit_transcript.py" \
    --raw "$CLAUDE_DEBUG_FILE" \
    --topic-id "$TOPIC_ID" \
    --summary-out "$TOPIC_DIR/debug_audit.json"; then
    KEEP_SESSION_DIR=1
    echo "error: claude debug log exposed a hidden evaluation artifact" >&2
    echo "kept failed session dir: $SESSION_DIR" >&2
    print_claude_diagnostics
    exit 1
  fi
fi

if ! REPORT_JSON="$(python3 "$ROOT_DIR/scripts/collect_skill_report.py" \
  --search-dir "$SESSION_WORK_DIR" \
  --topic-dir "$TOPIC_DIR" \
  --public-dir "$ROOT_DIR/reports/$RUN_SAFE/$TOPIC_ARTIFACT_SAFE" \
  --target-text "$TOPIC_DIR/input.txt" \
  --render-script "$RENDER_SCRIPT" \
  --summary-out "$TOPIC_DIR/skill_report_summary.json" \
  2>"$TOPIC_DIR/collect_report.stderr")"; then
  KEEP_SESSION_DIR=1
  echo "error: skill did not create reports/**/report.json" >&2
  echo "kept failed session dir: $SESSION_DIR" >&2
  print_claude_diagnostics
  echo "session files:" >&2
  find "$SESSION_DIR" -maxdepth 5 -type f | sort >&2 || true
  cat "$TOPIC_DIR/collect_report.stderr" >&2 || true
  exit 1
fi

python3 "$ROOT_DIR/scripts/validate_report.py" \
  --report "$REPORT_JSON" \
  --topic-id "$TOPIC_ID" \
  --run-id "$RUN_ID" \
  --summary-out "$TOPIC_DIR/validation.json" \
  --out-json "$TOPIC_DIR/dragun.json" \
  --out-jsonl "$RUN_JSONL"

echo "$TOPIC_DIR/dragun.json"
