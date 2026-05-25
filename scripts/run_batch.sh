#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOPICS="$ROOT_DIR/data/trec-2025-dragun-topics.jsonl"
SKILL="$ROOT_DIR/skills_under_test/lateral-reading-skill"
SKILL_COMMAND="${SKILL_COMMAND:-}"
MODEL="${MODEL:-}"
PROVIDER="${PROVIDER:-anthropic}"
AGENT="${AGENT:-}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-$CLAUDE_REASONING_EFFORT}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-never}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_WEB_SEARCH="${CODEX_WEB_SEARCH:-1}"
RUN_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-}"
CLAUDE_TOOLS_FALLBACK="WebFetch,WebSearch,Read,Write"
RUN_CLAUDE_TOOLS="${CLAUDE_TOOLS:-}"
OPENROUTER_WEB_SEARCH="${OPENROUTER_WEB_SEARCH:-1}"
OPENROUTER_WEB_SEARCH_ENGINE="${OPENROUTER_WEB_SEARCH_ENGINE:-auto}"
OPENROUTER_WEB_SEARCH_MAX_RESULTS="${OPENROUTER_WEB_SEARCH_MAX_RESULTS:-5}"
OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS="${OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS:-20}"
OPENROUTER_WEB_SEARCH_CONTEXT_SIZE="${OPENROUTER_WEB_SEARCH_CONTEXT_SIZE:-}"
OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS="${OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS:-}"
OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS="${OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS:-}"
OPENROUTER_WEB_FETCH="${OPENROUTER_WEB_FETCH:-1}"
OPENROUTER_WEB_FETCH_ENGINE="${OPENROUTER_WEB_FETCH_ENGINE:-auto}"
OPENROUTER_WEB_FETCH_MAX_USES="${OPENROUTER_WEB_FETCH_MAX_USES:-20}"
OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS="${OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS:-100000}"
OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS="${OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS:-}"
OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS="${OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS:-}"
RUN_ID="${RUN_ID:-}"
LIMIT=0
OVERWRITE=0
MAX_ATTEMPTS="${RUN_TOPIC_MAX_ATTEMPTS:-5}"
RETRY_DELAY_SECONDS="${RUN_TOPIC_RETRY_DELAY_SECONDS:-120}"

case "$CODEX_SANDBOX" in
  read-only|workspace-write|danger-full-access) ;;
  *) CODEX_SANDBOX="workspace-write" ;;
esac

openrouter_web_search_enabled() {
  case "$OPENROUTER_WEB_SEARCH" in
    0|false|False|FALSE|off|Off|OFF|no|No|NO|none|None|NONE) return 1 ;;
    *) return 0 ;;
  esac
}

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
  --skill-command CMD    Slash command to invoke, e.g. /plugin:skill
  --agent NAME           claude or codex; inferred from provider when omitted
  --model MODEL          Agent model name (provider-specific default)
  --provider NAME        anthropic, openai, or openrouter
  --effort EFFORT        Agent reasoning effort (default: high)
  --run-id ID            Output run ID
  --limit N              Run only the first N topics
  --overwrite            Replace existing run output
  --max-attempts N       Maximum attempts per article (default: 5)
  --retry-delay-seconds N
                        Seconds to wait after a failed attempt before retrying (default: 120)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topics) TOPICS="$2"; shift 2 ;;
    --skill) SKILL="$2"; shift 2 ;;
    --skill-command) SKILL_COMMAND="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; CODEX_REASONING_EFFORT="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --retry-delay-seconds) RETRY_DELAY_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$AGENT" ]]; then
  case "$PROVIDER" in
    anthropic) AGENT="claude" ;;
    openai|openrouter) AGENT="codex" ;;
    *) echo "error: unsupported provider: $PROVIDER" >&2; exit 2 ;;
  esac
fi
if [[ -z "$MODEL" ]]; then
  case "$PROVIDER" in
    anthropic) MODEL="sonnet" ;;
    openai) MODEL="gpt-5.5" ;;
    openrouter) MODEL="openai/gpt-5.2" ;;
  esac
fi
case "$AGENT:$PROVIDER" in
  claude:anthropic|codex:openai|codex:openrouter) ;;
  *)
    echo "error: unsupported agent/provider combination: $AGENT/$PROVIDER" >&2
    echo "supported: claude/anthropic, codex/openai, codex/openrouter" >&2
    exit 2
    ;;
esac
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${AGENT}_${PROVIDER}_${MODEL}_$(basename "$SKILL")")"
fi
if ! [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --max-attempts must be a positive integer" >&2
  exit 2
fi
if ! [[ "$RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "error: --retry-delay-seconds must be a nonnegative integer" >&2
  exit 2
fi
RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
if [[ "$AGENT" == "claude" ]]; then
  if [[ -z "$RUN_CLAUDE_TOOLS" ]]; then
    RUN_CLAUDE_TOOLS="$CLAUDE_TOOLS_FALLBACK"
  fi
  if [[ -z "$SKILL_COMMAND" ]]; then
    SKILL_COMMAND="$(python3 "$ROOT_DIR/scripts/resolve_skill_command.py" --skill "$SKILL")"
  fi
  if [[ -z "$RUN_PERMISSION_MODE" ]]; then
    RUN_PERMISSION_MODE="acceptEdits"
  fi
  export CLAUDE_PERMISSION_MODE="$RUN_PERMISSION_MODE"
  export CLAUDE_TOOLS="$RUN_CLAUDE_TOOLS"
else
  RUN_CLAUDE_TOOLS=""
  RUN_PERMISSION_MODE=""
fi
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
TOPIC_MAP="$RUN_DIR/topic_map.jsonl"
PRIVATE_TOPIC_DIR="$RUN_DIR/private_topic_ids"
python3 "$ROOT_DIR/scripts/list_topics.py" --topics "$TOPICS" --limit "$LIMIT" > "$TOPIC_LIST"
: > "$TOPIC_MAP"
mkdir -p "$PRIVATE_TOPIC_DIR"

TOTAL="$(wc -l < "$TOPIC_LIST" | tr -d ' ')"
CURRENT=0
START_TS="$(date +%s)"
while IFS= read -r TOPIC_ID; do
  CURRENT=$((CURRENT + 1))
  TOPIC_ALIAS="$(printf 'article_%03d' "$CURRENT")"
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
  TOPIC_ID_FILE="$PRIVATE_TOPIC_DIR/$TOPIC_ALIAS.txt"
  printf '%s\n' "$TOPIC_ID" > "$TOPIC_ID_FILE"
  echo "[$CURRENT/$TOTAL] start $TOPIC_ALIAS | elapsed $(format_duration "$ELAPSED") | eta $ETA_TEXT"
  TOPIC_DIR="$RUN_DIR/topics/$TOPIC_ALIAS"
  ATTEMPT=1
  while true; do
    if [[ "$ATTEMPT" -gt 1 ]]; then
      echo "[$CURRENT/$TOTAL] retry $TOPIC_ALIAS | attempt $ATTEMPT/$MAX_ATTEMPTS"
    fi
    set +e
    if [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; then
      RUN_ONE_QUIET_FAILURE=1 "$ROOT_DIR/scripts/run_one.sh" \
        --topics "$TOPICS" \
        --topic-id-file "$TOPIC_ID_FILE" \
        --topic-alias "$TOPIC_ALIAS" \
        --skill "$SKILL" \
        --skill-command "$SKILL_COMMAND" \
        --agent "$AGENT" \
        --model "$MODEL" \
        --provider "$PROVIDER" \
        --effort "$CLAUDE_REASONING_EFFORT" \
        --run-id "$RUN_ID" \
        --run-jsonl "$RUN_JSONL"
    else
      "$ROOT_DIR/scripts/run_one.sh" \
        --topics "$TOPICS" \
        --topic-id-file "$TOPIC_ID_FILE" \
        --topic-alias "$TOPIC_ALIAS" \
        --skill "$SKILL" \
        --skill-command "$SKILL_COMMAND" \
        --agent "$AGENT" \
        --model "$MODEL" \
        --provider "$PROVIDER" \
        --effort "$CLAUDE_REASONING_EFFORT" \
        --run-id "$RUN_ID" \
        --run-jsonl "$RUN_JSONL"
    fi
    ATTEMPT_STATUS=$?
    set -e
    if [[ "$ATTEMPT_STATUS" -eq 0 ]]; then
      break
    fi
    ATTEMPT_DIR="$RUN_DIR/failed_attempts/$TOPIC_ALIAS/attempt_$(printf '%02d' "$ATTEMPT")"
    mkdir -p "$(dirname "$ATTEMPT_DIR")"
    if [[ -d "$TOPIC_DIR" ]]; then
      rm -rf "$ATTEMPT_DIR"
      mv "$TOPIC_DIR" "$ATTEMPT_DIR"
    fi
    rm -rf "$ROOT_DIR/reports/$RUN_SAFE/$TOPIC_ALIAS"
    if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
      echo "error: $TOPIC_ALIAS failed on attempt $ATTEMPT/$MAX_ATTEMPTS" >&2
      echo "logs: $ATTEMPT_DIR" >&2
      exit "$ATTEMPT_STATUS"
    fi
    if [[ "$RETRY_DELAY_SECONDS" -gt 0 ]]; then
      echo "[$CURRENT/$TOTAL] failed $TOPIC_ALIAS | attempt $ATTEMPT/$MAX_ATTEMPTS | waiting ${RETRY_DELAY_SECONDS}s before retry"
      sleep "$RETRY_DELAY_SECONDS"
    else
      echo "[$CURRENT/$TOTAL] failed $TOPIC_ALIAS | attempt $ATTEMPT/$MAX_ATTEMPTS | retrying"
    fi
    ATTEMPT=$((ATTEMPT + 1))
  done
  if [[ "$ATTEMPT" -gt 1 ]]; then
    echo "[$CURRENT/$TOTAL] recovered $TOPIC_ALIAS | attempt $ATTEMPT/$MAX_ATTEMPTS"
  fi
  python3 - "$TOPIC_MAP" "$TOPIC_ALIAS" "$TOPIC_ID" <<'PY'
import json
import sys

path, alias, topic_id = sys.argv[1:]
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({"alias": alias, "topic_id": topic_id}, ensure_ascii=False) + "\n")
PY
  ARTICLE_END_TS="$(date +%s)"
  ARTICLE_SECONDS=$((ARTICLE_END_TS - ARTICLE_START_TS))
  ELAPSED=$((ARTICLE_END_TS - START_TS))
  COMPLETED="$CURRENT"
  AVG=$((ELAPSED / COMPLETED))
  REMAINING=$((TOTAL - CURRENT))
  ETA=$((AVG * REMAINING))
  echo "[$CURRENT/$TOTAL] done  $TOPIC_ALIAS | article $(format_duration "$ARTICLE_SECONDS") | elapsed $(format_duration "$ELAPSED") | eta $(format_duration "$ETA")"
done < "$TOPIC_LIST"

mkdir -p "$ROOT_DIR/data/runs/report_generation_runs"
cp "$RUN_JSONL" "$ROOT_DIR/data/runs/report_generation_runs/$RUN_ID"

cat > "$RUN_DIR/manifest.json" <<EOF
{
  "run_id": "$RUN_ID",
  "agent": "$AGENT",
  "model": "$MODEL",
  "provider": "$PROVIDER",
  "claude_reasoning_effort": "$CLAUDE_REASONING_EFFORT",
  "claude_permission_mode": "$RUN_PERMISSION_MODE",
  "claude_tools": "$RUN_CLAUDE_TOOLS",
  "codex_reasoning_effort": "$CODEX_REASONING_EFFORT",
  "codex_approval_policy": "$CODEX_APPROVAL_POLICY",
  "codex_sandbox": "$CODEX_SANDBOX",
  "codex_web_search": "$CODEX_WEB_SEARCH",
  "max_attempts": "$MAX_ATTEMPTS",
  "retry_delay_seconds": "$RETRY_DELAY_SECONDS",
  "openrouter_web_search": "$OPENROUTER_WEB_SEARCH",
  "openrouter_web_search_engine": "$OPENROUTER_WEB_SEARCH_ENGINE",
  "openrouter_web_search_max_results": "$OPENROUTER_WEB_SEARCH_MAX_RESULTS",
  "openrouter_web_search_max_total_results": "$OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS",
  "openrouter_web_search_context_size": "$OPENROUTER_WEB_SEARCH_CONTEXT_SIZE",
  "openrouter_web_search_allowed_domains": "$OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS",
  "openrouter_web_search_excluded_domains": "$OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS",
  "openrouter_web_fetch": "$OPENROUTER_WEB_FETCH",
  "openrouter_web_fetch_engine": "$OPENROUTER_WEB_FETCH_ENGINE",
  "openrouter_web_fetch_max_uses": "$OPENROUTER_WEB_FETCH_MAX_USES",
  "openrouter_web_fetch_max_content_tokens": "$OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS",
  "openrouter_web_fetch_allowed_domains": "$OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS",
  "openrouter_web_fetch_blocked_domains": "$OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS",
  "skill": "$SKILL",
  "skill_command": "$SKILL_COMMAND",
  "skill_commit": "$SKILL_COMMIT",
  "skill_file": "$SKILL_FILE",
  "topics": "$TOPICS",
  "topic_map": "$TOPIC_MAP",
  "run_jsonl": "$RUN_JSONL",
  "reports_dir": "$ROOT_DIR/reports/$RUN_SAFE",
  "topic_id_hidden_from_model": true,
  "claude_no_session_persistence": true,
  "codex_ephemeral": true,
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo "run jsonl: $RUN_JSONL"
echo "autojudge input: $ROOT_DIR/data/runs/report_generation_runs/$RUN_ID"
echo "skill reports: $ROOT_DIR/reports/$RUN_SAFE"
