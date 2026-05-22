#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOPICS="$ROOT_DIR/data/trec-2025-dragun-topics.jsonl"
TOPIC_ID=""
TOPIC_ALIAS=""
SKILL="$ROOT_DIR/skills_under_test/lateral-reading-skill"
MODEL="${MODEL:-sonnet}"
PROVIDER="${PROVIDER:-anthropic}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
RUN_ID="${RUN_ID:-}"
RUN_JSONL=""
MAX_BUDGET_USD="${MAX_BUDGET_USD:-5.00}"
PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-}"
KEEP_SESSION_DIR="${KEEP_SESSION_DIR:-0}"
OVERWRITE_TOPIC="${OVERWRITE_TOPIC:-0}"
LOCK_SKILL_DIR="${LOCK_SKILL_DIR:-1}"
DEFAULT_ALLOWED_TOOLS=(
  WebFetch
  WebSearch
  Read
  Write
  "Bash(mkdir -p reports*)"
  "Bash(python3 skills/*/scripts/render_report_html.py *)"
  "Bash(python skills/*/scripts/render_report_html.py *)"
  "Bash(python3 skills/*/scripts/validate_report.py *)"
  "Bash(python skills/*/scripts/validate_report.py *)"
)

usage() {
  cat <<'EOF'
usage: scripts/run_one.sh --topic-id ID [options]

Options:
  --topics PATH          topics JSONL
  --skill PATH           Skill repo to test
  --topic-alias NAME     Anonymous artifact folder name for this topic
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
    --topic-alias) TOPIC_ALIAS="$2"; shift 2 ;;
    --skill) SKILL="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --run-jsonl) RUN_JSONL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$TOPIC_ID" ]]; then
  echo "error: --topic-id is required" >&2
  exit 2
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${PROVIDER}_${MODEL}_$(basename "$SKILL")")"
fi
RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
if [[ -z "$PERMISSION_MODE" ]]; then
  if [[ "$PROVIDER" == "openrouter" ]]; then
    PERMISSION_MODE="default"
  else
    PERMISSION_MODE="auto"
  fi
fi

RUN_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
TOPIC_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$TOPIC_ID")"
if [[ -z "$TOPIC_ALIAS" ]]; then
  TOPIC_ALIAS="$(python3 -c 'import hashlib, sys; print("topic_" + hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$TOPIC_ID")"
fi
TOPIC_ARTIFACT_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$TOPIC_ALIAS")"
RUN_DIR="$ROOT_DIR/runs/$RUN_SAFE"
TOPIC_DIR="$RUN_DIR/topics/$TOPIC_ARTIFACT_SAFE"
if [[ -z "$RUN_JSONL" ]]; then
  RUN_JSONL="$RUN_DIR/dragun_task2.jsonl"
fi
CLAUDE_STDOUT="$TOPIC_DIR/claude_raw.json"
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
SESSION_SYSTEM_PROMPT="$SESSION_DIR/session_system_prompt.md"
SESSION_CLAUDE_DEBUG_FILE="$SESSION_DIR/claude_debug.log"
cleanup() {
  if [[ "$KEEP_SESSION_DIR" != "1" ]]; then
    chmod -R u+w "$SESSION_DIR" 2>/dev/null || true
    rm -rf "$SESSION_DIR"
  else
    echo "kept session dir: $SESSION_DIR" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$SESSION_DIR/skill"
python3 "$ROOT_DIR/scripts/make_article_input.py" \
  --topics "$TOPICS" \
  --topic-id "$TOPIC_ID" \
  --out-text "$TOPIC_DIR/input.txt"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude .git "$SKILL"/ "$SESSION_DIR/skill"/
else
  cp -R "$SKILL"/. "$SESSION_DIR/skill"/
  rm -rf "$SESSION_DIR/skill/.git"
fi
SKILL_FILE="$(python3 "$ROOT_DIR/scripts/resolve_skill_file.py" --skill "$SESSION_DIR/skill")"
RENDER_SCRIPT=""
if [[ -f "$SESSION_DIR/skill/skills/lateral-reading/scripts/render_report_html.py" ]]; then
  RENDER_SCRIPT="$SESSION_DIR/skill/skills/lateral-reading/scripts/render_report_html.py"
else
  RENDER_SCRIPT="$(find "$SESSION_DIR/skill" -path "*/scripts/render_report_html.py" -type f -print -quit)"
fi

if [[ "$LOCK_SKILL_DIR" == "1" ]]; then
  mkdir -p "$SESSION_DIR/skill/reports"
  chmod -R u-w "$SESSION_DIR/skill"
  chmod u+w "$SESSION_DIR/skill/reports"
fi

cp "$TOPIC_DIR/input.txt" "$SESSION_DIR/prompt.txt"
{
  cat "$SKILL_FILE"
  cat <<'EOF'

## Noninteractive Session Constraints

This is a noninteractive run. Do not ask the user for permission or approval.
Use WebSearch and WebFetch for web search and retrieval. Do not use Bash for web access, search, directory discovery, reading files, or Python snippets.
Use Bash only for the explicitly allowed local report commands: creating a reports folder, running the skill's report validator, and rendering report HTML with the skill's render script.
The skill files are read-only. Do not modify scripts, references, examples, schemas, or plugin files.
Use relative paths under the current workspace, and write the required report artifacts only under `reports/`.
If a tool request is denied, continue with the allowed tools and still produce `reports/.../report.json`.
EOF
} > "$SESSION_SYSTEM_PROMPT"

CLAUDE_ARGS=(
  --print
  --plugin-dir "$SESSION_DIR/skill"
  --append-system-prompt-file "$SESSION_SYSTEM_PROMPT"
  --no-session-persistence
  --permission-mode "$PERMISSION_MODE"
  --max-budget-usd "$MAX_BUDGET_USD"
  --model "$MODEL"
  --effort "$CLAUDE_REASONING_EFFORT"
)
if [[ "${CLAUDE_DEBUG_LOG:-0}" == "1" ]]; then
  CLAUDE_ARGS+=(--debug-file "$SESSION_CLAUDE_DEBUG_FILE")
fi
if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
  CLAUDE_ARGS+=(--allowed-tools "$ALLOWED_TOOLS")
else
  CLAUDE_ARGS+=(--allowed-tools "${DEFAULT_ALLOWED_TOOLS[@]}")
fi

export CLAUDE_CODE_EFFORT_LEVEL="$CLAUDE_REASONING_EFFORT"

if [[ "${CLAUDE_BARE:-auto}" == "1" || ( "${CLAUDE_BARE:-auto}" == "auto" && "$PROVIDER" == "openrouter" ) || ( "${CLAUDE_BARE:-auto}" == "auto" && -n "${ANTHROPIC_API_KEY:-}" ) ]]; then
  CLAUDE_ARGS=(--bare "${CLAUDE_ARGS[@]}")
else
  CLAUDE_ARGS+=(--setting-sources project)
fi

if [[ "$PROVIDER" == "openrouter" ]]; then
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "error: OPENROUTER_API_KEY is required for --provider openrouter" >&2
    exit 2
  fi
  export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://openrouter.ai/api}"
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

set +e
(
  cd "$SESSION_DIR/skill"
  claude "${CLAUDE_ARGS[@]}" "$(cat "$SESSION_DIR/prompt.txt")"
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

python3 "$ROOT_DIR/scripts/audit_transcript.py" \
  --raw "$CLAUDE_STDOUT" \
  --topic-id "$TOPIC_ID" \
  --summary-out "$TOPIC_DIR/transcript_audit.json"
if [[ -s "$CLAUDE_DEBUG_FILE" ]]; then
  python3 "$ROOT_DIR/scripts/audit_transcript.py" \
    --raw "$CLAUDE_DEBUG_FILE" \
    --topic-id "$TOPIC_ID" \
    --summary-out "$TOPIC_DIR/debug_audit.json"
fi

if ! REPORT_JSON="$(python3 "$ROOT_DIR/scripts/collect_skill_report.py" \
  --search-dir "$SESSION_DIR/skill" \
  --topic-dir "$TOPIC_DIR" \
  --public-dir "$ROOT_DIR/reports/$RUN_SAFE/$TOPIC_ARTIFACT_SAFE" \
  --fallback-raw "$CLAUDE_STDOUT" \
  --target-text "$TOPIC_DIR/input.txt" \
  --render-script "$RENDER_SCRIPT" \
  --summary-out "$TOPIC_DIR/skill_report_summary.json" 2>"$TOPIC_DIR/collect_report.stderr")"; then
  KEEP_SESSION_DIR=1
  echo "error: skill did not create reports/**/report.json" >&2
  echo "kept failed session dir: $SESSION_DIR" >&2
  print_claude_diagnostics
  echo "session files:" >&2
  find "$SESSION_DIR/skill" -maxdepth 4 -type f | sort >&2 || true
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
