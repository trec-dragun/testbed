#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOPICS="$ROOT_DIR/data/trec-2025-dragun-topics.jsonl"
TOPIC_ID=""
TOPIC_ID_FILE=""
TOPIC_ALIAS=""
SKILL="$ROOT_DIR/skills_under_test/lateral-reading-skill"
SKILL_COMMAND="${SKILL_COMMAND:-}"
MODEL="${MODEL:-}"
PROVIDER="${PROVIDER:-anthropic}"
AGENT="${AGENT:-}"
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-high}"
PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
CLAUDE_TOOLS_FALLBACK="WebFetch,WebSearch,Read,Write"
CLAUDE_TOOLS_DEFAULT="${CLAUDE_TOOLS:-}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-$CLAUDE_REASONING_EFFORT}"
CODEX_APPROVAL_POLICY="${CODEX_APPROVAL_POLICY:-never}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_WEB_SEARCH="${CODEX_WEB_SEARCH:-1}"
CODEX_TRACE="${CODEX_TRACE:-1}"
CODEX_HOME_SOURCE="${CODEX_HOME_SOURCE:-${CODEX_HOME:-$HOME/.codex}}"
CODEX_OPENROUTER_WIRE_API="${CODEX_OPENROUTER_WIRE_API:-responses}"
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
RUN_JSONL=""
MAX_BUDGET_USD="${MAX_BUDGET_USD:-5.00}"
KEEP_SESSION_DIR="${KEEP_SESSION_DIR:-0}"
OVERWRITE_TOPIC="${OVERWRITE_TOPIC:-0}"
OPENROUTER_SERVICE_TIER="${OPENROUTER_SERVICE_TIER:-auto}"
OPENROUTER_PROXY_PID=""
CLAUDE_TRACE="${CLAUDE_TRACE:-1}"
QUIET_FAILURE="${RUN_ONE_QUIET_FAILURE:-0}"
RUNNER_ARTIFACT_NOTE="${RUNNER_ARTIFACT_NOTE:-1}"

case "$CODEX_SANDBOX" in
  read-only|workspace-write|danger-full-access) ;;
  *) CODEX_SANDBOX="workspace-write" ;;
esac

bool_enabled() {
  case "$1" in
    0|false|False|FALSE|off|Off|OFF|no|No|NO|none|None|NONE) return 1 ;;
    *) return 0 ;;
  esac
}

openrouter_web_search_enabled() {
  bool_enabled "$OPENROUTER_WEB_SEARCH"
}

openrouter_web_fetch_enabled() {
  bool_enabled "$OPENROUTER_WEB_FETCH"
}

codex_web_search_enabled() {
  bool_enabled "$CODEX_WEB_SEARCH"
}

usage() {
  cat <<'EOF'
usage: scripts/run_one.sh --topic-id ID [options]

Options:
  --topics PATH          topics JSONL
  --skill PATH           Skill repo to test
  --skill-command CMD    Slash command to invoke, e.g. /plugin:skill
  --topic-alias NAME     Anonymous artifact folder name for this topic
  --topic-id-file PATH   Read the topic ID from a private file instead of argv
  --agent NAME           claude or codex; inferred from provider when omitted
  --model MODEL          Agent model name (provider-specific default)
  --provider NAME        anthropic, openai, or openrouter
  --effort EFFORT        Agent reasoning effort (default: high)
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
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --effort) CLAUDE_REASONING_EFFORT="$2"; CODEX_REASONING_EFFORT="$2"; shift 2 ;;
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

if [[ "$AGENT" == "claude" ]]; then
  if [[ -z "$CLAUDE_TOOLS_DEFAULT" ]]; then
    CLAUDE_TOOLS_DEFAULT="$CLAUDE_TOOLS_FALLBACK"
  fi
  if [[ -z "$SKILL_COMMAND" ]]; then
    SKILL_COMMAND="$(python3 "$ROOT_DIR/scripts/resolve_skill_command.py" --skill "$SKILL")"
  fi
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "${AGENT}_${PROVIDER}_${MODEL}_$(basename "$SKILL")")"
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
CLAUDE_STREAM="$TOPIC_DIR/claude_stream.jsonl"
CLAUDE_TRAJECTORY="$TOPIC_DIR/trajectory_summary.json"
CLAUDE_STDERR="$TOPIC_DIR/claude_stderr.log"
CLAUDE_EXIT_CODE="$TOPIC_DIR/claude_exit_code.txt"
CLAUDE_DEBUG_FILE="$TOPIC_DIR/claude_debug.log"
if [[ "$CLAUDE_TRACE" == "1" ]]; then
  CLAUDE_STDOUT="$CLAUDE_STREAM"
fi
CODEX_STREAM="$TOPIC_DIR/codex_stream.jsonl"
CODEX_RAW="$TOPIC_DIR/codex_raw.txt"
CODEX_TRAJECTORY="$TOPIC_DIR/codex_trajectory_summary.json"
CODEX_STDERR="$TOPIC_DIR/codex_stderr.log"
CODEX_EXIT_CODE="$TOPIC_DIR/codex_exit_code.txt"
CODEX_LAST_MESSAGE="$TOPIC_DIR/codex_last_message.txt"
CODEX_CONFIG="$TOPIC_DIR/codex_config.toml"
AGENT_AUDIT_RAW="$CLAUDE_STDOUT"
CHAT_OUTPUTS=("$TOPIC_DIR/claude_raw.txt")

if [[ "$OVERWRITE_TOPIC" == "1" && -d "$TOPIC_DIR" ]]; then
  rm -rf "$TOPIC_DIR"
fi
mkdir -p "$TOPIC_DIR"

print_agent_diagnostics() {
  if [[ "$AGENT" == "codex" ]]; then
    echo "codex chat tail: $CODEX_RAW" >&2
    if [[ -s "$CODEX_RAW" ]]; then
      tail -n 80 "$CODEX_RAW" >&2 || true
    else
      echo "(empty)" >&2
    fi
    if [[ "$CODEX_TRACE" == "1" && -s "$CODEX_STREAM" ]]; then
      echo "codex stream tail: $CODEX_STREAM" >&2
      tail -n 40 "$CODEX_STREAM" >&2 || true
    fi
    if [[ -s "$CODEX_TRAJECTORY" ]]; then
      echo "trajectory summary: $CODEX_TRAJECTORY" >&2
    fi
    echo "codex stderr tail: $CODEX_STDERR" >&2
    if [[ -s "$CODEX_STDERR" ]]; then
      tail -n 120 "$CODEX_STDERR" >&2 || true
    else
      echo "(empty)" >&2
    fi
    return
  fi
  if [[ "$CLAUDE_TRACE" == "1" && -s "$TOPIC_DIR/claude_raw.txt" ]]; then
    echo "claude chat tail: $TOPIC_DIR/claude_raw.txt" >&2
    tail -n 80 "$TOPIC_DIR/claude_raw.txt" >&2 || true
  else
    echo "claude stdout tail: $CLAUDE_STDOUT" >&2
    if [[ -s "$CLAUDE_STDOUT" ]]; then
      tail -n 80 "$CLAUDE_STDOUT" >&2 || true
    else
      echo "(empty)" >&2
    fi
  fi
  if [[ "$CLAUDE_TRACE" == "1" && -s "$CLAUDE_STREAM" ]]; then
    echo "claude stream tail: $CLAUDE_STREAM" >&2
    tail -n 40 "$CLAUDE_STREAM" >&2 || true
  fi
  if [[ "$CLAUDE_TRACE" == "1" && -s "$CLAUDE_TRAJECTORY" ]]; then
    echo "trajectory summary: $CLAUDE_TRAJECTORY" >&2
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
SESSION_CODEX_HOME="$SESSION_DIR/codex_home"

cleanup() {
  if [[ -n "$OPENROUTER_PROXY_PID" ]]; then
    kill "$OPENROUTER_PROXY_PID" 2>/dev/null || true
    wait "$OPENROUTER_PROXY_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP_SESSION_DIR" != "1" || "$QUIET_FAILURE" == "1" ]]; then
    chmod -R u+w "$SESSION_DIR" 2>/dev/null || true
    rm -rf "$SESSION_DIR"
  else
    echo "kept session dir: $SESSION_DIR" >&2
  fi
}
trap cleanup EXIT

write_runner_artifact_note() {
  if [[ "$AGENT" == "claude" ]]; then
    cat <<'EOF'
Automated artifact note:
- For this automated run, override any timestamped-path examples in the skill instructions and use the exact paths below.
- Use the available Write tool before your final answer.
- Write the normalized target article to this exact path:
  file_path: reports/lateral-reading/target.txt
- Write the structured report JSON to this exact path:
  file_path: reports/lateral-reading/report.json
- The Write tool accepts exactly these required parameters: file_path and content.
- Never call Write with empty input; include file_path and content in the same tool call.
- The Write tool creates parent directories automatically; do not stop because the reports directory is missing.
- The report.json content must be a JSON object exactly shaped as {"responses":[...]}.
- If the Write tool is unavailable or repeatedly fails, return only the report JSON wrapped in:
  <report_json>{"responses":[...]}</report_json>
- If Bash, shell validation, or HTML rendering is unavailable, skip those steps; the runner renders report.html after the session.
- Do not stop with a prose-only chat answer because validation or rendering tools are unavailable.
- The output contract in this note is sufficient; do not stop if local reference files cannot be read.
- When reading .md or .txt files with the Read tool, do not pass pages unless the tool explicitly requires it.

EOF
    return
  fi
  cat <<'EOF'
Automated artifact note:
- For this automated run, override any timestamped-path examples in the skill instructions and use the exact paths below.
- Use available filesystem or shell tools before your final answer.
- Write the normalized target article to this exact path:
  reports/lateral-reading/target.txt
- Write the structured report JSON to this exact path:
  reports/lateral-reading/report.json
- The report.json content must be a JSON object exactly shaped as {"responses":[...]}.
- If file writing is unavailable or repeatedly fails, return only the report JSON wrapped in:
  <report_json>{"responses":[...]}</report_json>
- If shell validation or HTML rendering is unavailable, skip those steps; the runner renders report.html after the session.
- Do not stop with a prose-only chat answer because validation or rendering tools are unavailable.
- The output contract in this note is sufficient; do not stop if local reference files cannot be read.

EOF
}

openrouter_effective_service_tier() {
  local requested="$OPENROUTER_SERVICE_TIER"
  if [[ "$requested" == "auto" ]]; then
    case "$MODEL" in
      openai/*|google/*) requested="flex" ;;
      *) requested="" ;;
    esac
  fi
  printf '%s\n' "$requested"
}

openrouter_proxy_needed() {
  local service_tier="$1"
  if [[ "$service_tier" != "off" && "$service_tier" != "none" && -n "$service_tier" ]]; then
    return 0
  fi
  if openrouter_web_search_enabled || openrouter_web_fetch_enabled; then
    return 0
  fi
  return 1
}

start_openrouter_proxy() {
  local base_url="$1"
  local service_tier="$2"
  local port_file="$SESSION_DIR/openrouter_proxy.port"
  local proxy_log="$TOPIC_DIR/openrouter_proxy.log"
  local args=(--base-url "$base_url")
  if [[ "$service_tier" != "off" && "$service_tier" != "none" && -n "$service_tier" ]]; then
    args+=(--service-tier "$service_tier")
  fi
  if openrouter_web_search_enabled; then
    args+=(--web-search)
    if [[ -n "$OPENROUTER_WEB_SEARCH_ENGINE" ]]; then
      args+=(--web-search-engine "$OPENROUTER_WEB_SEARCH_ENGINE")
    fi
    if [[ -n "$OPENROUTER_WEB_SEARCH_MAX_RESULTS" ]]; then
      args+=(--web-search-max-results "$OPENROUTER_WEB_SEARCH_MAX_RESULTS")
    fi
    if [[ -n "$OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS" ]]; then
      args+=(--web-search-max-total-results "$OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS")
    fi
    if [[ -n "$OPENROUTER_WEB_SEARCH_CONTEXT_SIZE" ]]; then
      args+=(--web-search-context-size "$OPENROUTER_WEB_SEARCH_CONTEXT_SIZE")
    fi
    if [[ -n "$OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS" ]]; then
      args+=(--web-search-allowed-domains "$OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS")
    fi
    if [[ -n "$OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS" ]]; then
      args+=(--web-search-excluded-domains "$OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS")
    fi
  fi
  if openrouter_web_fetch_enabled; then
    args+=(--web-fetch)
    if [[ -n "$OPENROUTER_WEB_FETCH_ENGINE" ]]; then
      args+=(--web-fetch-engine "$OPENROUTER_WEB_FETCH_ENGINE")
    fi
    if [[ -n "$OPENROUTER_WEB_FETCH_MAX_USES" ]]; then
      args+=(--web-fetch-max-uses "$OPENROUTER_WEB_FETCH_MAX_USES")
    fi
    if [[ -n "$OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS" ]]; then
      args+=(--web-fetch-max-content-tokens "$OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS")
    fi
    if [[ -n "$OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS" ]]; then
      args+=(--web-fetch-allowed-domains "$OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS")
    fi
    if [[ -n "$OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS" ]]; then
      args+=(--web-fetch-blocked-domains "$OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS")
    fi
  fi
  python3 "$ROOT_DIR/scripts/openrouter_service_tier_proxy.py" \
    "${args[@]}" \
    --port-file "$port_file" \
    >"$proxy_log" 2>&1 &
  OPENROUTER_PROXY_PID=$!
  for _ in {1..50}; do
    if [[ -s "$port_file" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ ! -s "$port_file" ]]; then
    echo "error: OpenRouter request proxy did not start" >&2
    cat "$proxy_log" >&2 || true
    exit 1
  fi
  OPENROUTER_PROXY_PORT="$(<"$port_file")"
}

url_path() {
  python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).path.rstrip("/"))' "$1"
}

prepare_codex_home() {
  mkdir -p "$SESSION_CODEX_HOME/skills"
  local source_skill_dir="$SESSION_WORK_DIR/skills/$SKILL_NAME"
  if [[ ! -d "$source_skill_dir" ]]; then
    source_skill_dir="$(dirname "$(python3 "$ROOT_DIR/scripts/resolve_skill_file.py" --skill "$SKILL")")"
  fi
  cp -R "$source_skill_dir" "$SESSION_CODEX_HOME/skills/$SKILL_NAME"

  local auth_source="$CODEX_HOME_SOURCE/auth.json"
  if [[ -f "$auth_source" ]]; then
    cp "$auth_source" "$SESSION_CODEX_HOME/auth.json"
    chmod 600 "$SESSION_CODEX_HOME/auth.json" 2>/dev/null || true
  fi
}

write_codex_config() {
  local provider_base_url="$1"
  local web_search_enabled="$2"
  local trusted_dir="$SESSION_WORK_DIR"
  {
    printf 'model = "%s"\n' "$MODEL"
    if [[ "$PROVIDER" == "openrouter" ]]; then
      printf 'model_provider = "openrouter"\n'
    fi
    printf 'model_reasoning_effort = "%s"\n' "$CODEX_REASONING_EFFORT"
    printf 'approval_policy = "%s"\n' "$CODEX_APPROVAL_POLICY"
    printf 'sandbox_mode = "%s"\n' "$CODEX_SANDBOX"
    printf 'disable_response_storage = true\n'
    if [[ "$web_search_enabled" == "1" ]]; then
      printf '\n[tools]\nweb_search = true\n'
    fi
    printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$trusted_dir"
    if [[ "$PROVIDER" == "openrouter" ]]; then
      printf '\n[model_providers.openrouter]\n'
      printf 'name = "OpenRouter"\n'
      printf 'base_url = "%s"\n' "$provider_base_url"
      printf 'env_key = "OPENROUTER_API_KEY"\n'
      printf 'wire_api = "%s"\n' "$CODEX_OPENROUTER_WIRE_API"
      printf 'requires_openai_auth = false\n'
    fi
  } > "$SESSION_CODEX_HOME/config.toml"
  cp "$SESSION_CODEX_HOME/config.toml" "$CODEX_CONFIG"
}

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
SKILL_NAME="$(python3 "$ROOT_DIR/scripts/resolve_skill_name.py" --skill "$SKILL")"

{
  if [[ "$AGENT" == "claude" ]]; then
    printf '%s\n\n' "$SKILL_COMMAND"
  else
    printf 'Use $%s for this automated lateral-reading run.\n\n' "$SKILL_NAME"
  fi
  if [[ "$RUNNER_ARTIFACT_NOTE" == "1" ]]; then
    write_runner_artifact_note
  fi
  cat "$TOPIC_DIR/input.txt"
} > "$SESSION_PROMPT"

if [[ "$AGENT" == "claude" ]]; then
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
  if [[ "$CLAUDE_TRACE" == "1" ]]; then
    CLAUDE_ARGS+=(--output-format stream-json --verbose)
  fi

  export CLAUDE_CODE_EFFORT_LEVEL="$CLAUDE_REASONING_EFFORT"
  export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1

  if [[ "${CLAUDE_BARE:-0}" == "1" ]]; then
    CLAUDE_ARGS=(--bare "${CLAUDE_ARGS[@]}")
  else
    CLAUDE_ARGS+=(--setting-sources project)
  fi

  : > "$CLAUDE_STDOUT"
  : > "$CLAUDE_STDERR"
  set +e
  (
    cd "$SESSION_WORK_DIR"
    claude "${CLAUDE_ARGS[@]}" < "$SESSION_PROMPT"
  ) > "$CLAUDE_STDOUT" 2>"$CLAUDE_STDERR"
  AGENT_STATUS=$?
  set -e

  if [[ -s "$SESSION_CLAUDE_DEBUG_FILE" ]]; then
    cp "$SESSION_CLAUDE_DEBUG_FILE" "$CLAUDE_DEBUG_FILE"
  fi
  if [[ "$CLAUDE_TRACE" == "1" && -s "$CLAUDE_STREAM" ]]; then
    python3 "$ROOT_DIR/scripts/extract_claude_trajectory.py" \
      --stream "$CLAUDE_STREAM" \
      --summary-out "$CLAUDE_TRAJECTORY" \
      --chat-out "$TOPIC_DIR/claude_raw.txt" || true
  fi
  printf '%s\n' "$AGENT_STATUS" > "$CLAUDE_EXIT_CODE"
  AGENT_AUDIT_RAW="$CLAUDE_STDOUT"
  if [[ "$CLAUDE_TRACE" == "1" && -s "$TOPIC_DIR/claude_raw.txt" ]]; then
    AGENT_AUDIT_RAW="$TOPIC_DIR/claude_raw.txt"
  fi
  CHAT_OUTPUTS=("$TOPIC_DIR/claude_raw.txt")
  if [[ "$AGENT_STATUS" -ne 0 ]]; then
    KEEP_SESSION_DIR=1
    if [[ "$QUIET_FAILURE" != "1" ]]; then
      echo "error: claude exited with status $AGENT_STATUS" >&2
      echo "kept failed session dir: $SESSION_DIR" >&2
      print_agent_diagnostics
    fi
    exit "$AGENT_STATUS"
  fi
else
  prepare_codex_home
  CODEX_PROVIDER_BASE_URL=""
  CODEX_ENABLE_NATIVE_WEB_SEARCH=0
  if [[ "$PROVIDER" == "openrouter" ]]; then
    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
      echo "error: OPENROUTER_API_KEY is required for --provider openrouter" >&2
      exit 2
    fi
    OPENROUTER_UPSTREAM_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
    OPENROUTER_EFFECTIVE_SERVICE_TIER="$(openrouter_effective_service_tier)"
    if openrouter_proxy_needed "$OPENROUTER_EFFECTIVE_SERVICE_TIER"; then
      start_openrouter_proxy "$OPENROUTER_UPSTREAM_BASE_URL" "$OPENROUTER_EFFECTIVE_SERVICE_TIER"
      OPENROUTER_BASE_PATH="$(url_path "$OPENROUTER_UPSTREAM_BASE_URL")"
      CODEX_PROVIDER_BASE_URL="http://127.0.0.1:${OPENROUTER_PROXY_PORT}${OPENROUTER_BASE_PATH}"
    else
      CODEX_PROVIDER_BASE_URL="$OPENROUTER_UPSTREAM_BASE_URL"
    fi
  else
    if codex_web_search_enabled; then
      CODEX_ENABLE_NATIVE_WEB_SEARCH=1
    fi
  fi
  write_codex_config "$CODEX_PROVIDER_BASE_URL" "$CODEX_ENABLE_NATIVE_WEB_SEARCH"

  CODEX_ARGS=(
    exec
    --ephemeral
    --skip-git-repo-check
    --sandbox "$CODEX_SANDBOX"
    --model "$MODEL"
    --output-last-message "$CODEX_LAST_MESSAGE"
    -C "$SESSION_WORK_DIR"
  )
  if [[ "$CODEX_TRACE" == "1" ]]; then
    CODEX_ARGS+=(--json)
    CODEX_STDOUT="$CODEX_STREAM"
  else
    CODEX_STDOUT="$CODEX_RAW"
  fi

  : > "$CODEX_STDOUT"
  : > "$CODEX_STDERR"
  set +e
  CODEX_HOME="$SESSION_CODEX_HOME" codex "${CODEX_ARGS[@]}" - \
    < "$SESSION_PROMPT" > "$CODEX_STDOUT" 2>"$CODEX_STDERR"
  AGENT_STATUS=$?
  set -e

  if [[ "$CODEX_TRACE" == "1" && -s "$CODEX_STREAM" ]]; then
    python3 "$ROOT_DIR/scripts/extract_codex_trajectory.py" \
      --stream "$CODEX_STREAM" \
      --summary-out "$CODEX_TRAJECTORY" \
      --chat-out "$CODEX_RAW" \
      --last-message "$CODEX_LAST_MESSAGE" || true
  elif [[ -s "$CODEX_LAST_MESSAGE" ]]; then
    cp "$CODEX_LAST_MESSAGE" "$CODEX_RAW"
  fi
  printf '%s\n' "$AGENT_STATUS" > "$CODEX_EXIT_CODE"
  AGENT_AUDIT_RAW="$CODEX_RAW"
  CHAT_OUTPUTS=("$CODEX_RAW" "$CODEX_LAST_MESSAGE")
  if [[ "$AGENT_STATUS" -ne 0 ]]; then
    KEEP_SESSION_DIR=1
    if [[ "$QUIET_FAILURE" != "1" ]]; then
      echo "error: codex exited with status $AGENT_STATUS" >&2
      echo "kept failed session dir: $SESSION_DIR" >&2
      print_agent_diagnostics
    fi
    exit "$AGENT_STATUS"
  fi
fi

AUDIT_STDERR="$TOPIC_DIR/transcript_audit.stderr"
AUDIT_CMD=(
  python3 "$ROOT_DIR/scripts/audit_transcript.py"
  --raw "$AGENT_AUDIT_RAW"
  --topic-id "$TOPIC_ID"
  --summary-out "$TOPIC_DIR/transcript_audit.json"
)
set +e
if [[ "$QUIET_FAILURE" == "1" ]]; then
  "${AUDIT_CMD[@]}" 2>"$AUDIT_STDERR"
  AUDIT_STATUS=$?
else
  "${AUDIT_CMD[@]}"
  AUDIT_STATUS=$?
fi
set -e
if [[ "$AUDIT_STATUS" -ne 0 ]]; then
  KEEP_SESSION_DIR=1
  if [[ "$QUIET_FAILURE" != "1" ]]; then
    echo "error: $AGENT output exposed a hidden evaluation artifact" >&2
    echo "kept failed session dir: $SESSION_DIR" >&2
    print_agent_diagnostics
  fi
  exit 1
fi
if [[ "$AGENT" == "claude" && -s "$CLAUDE_DEBUG_FILE" ]]; then
  DEBUG_AUDIT_STDERR="$TOPIC_DIR/debug_audit.stderr"
  DEBUG_AUDIT_CMD=(
    python3 "$ROOT_DIR/scripts/audit_transcript.py"
    --raw "$CLAUDE_DEBUG_FILE"
    --topic-id "$TOPIC_ID"
    --summary-out "$TOPIC_DIR/debug_audit.json"
  )
  set +e
  if [[ "$QUIET_FAILURE" == "1" ]]; then
    "${DEBUG_AUDIT_CMD[@]}" 2>"$DEBUG_AUDIT_STDERR"
    DEBUG_AUDIT_STATUS=$?
  else
    "${DEBUG_AUDIT_CMD[@]}"
    DEBUG_AUDIT_STATUS=$?
  fi
  set -e
  if [[ "$DEBUG_AUDIT_STATUS" -ne 0 ]]; then
    KEEP_SESSION_DIR=1
    if [[ "$QUIET_FAILURE" != "1" ]]; then
      echo "error: claude debug log exposed a hidden evaluation artifact" >&2
      echo "kept failed session dir: $SESSION_DIR" >&2
      print_agent_diagnostics
    fi
    exit 1
  fi
fi

REPORT_CHAT_ARGS=()
for chat_output in "${CHAT_OUTPUTS[@]}"; do
  REPORT_CHAT_ARGS+=(--chat-output "$chat_output")
done

if ! REPORT_JSON="$(python3 "$ROOT_DIR/scripts/collect_skill_report.py" \
  --search-dir "$SESSION_WORK_DIR" \
  --topic-dir "$TOPIC_DIR" \
  --public-dir "$ROOT_DIR/reports/$RUN_SAFE/$TOPIC_ARTIFACT_SAFE" \
  --target-text "$TOPIC_DIR/input.txt" \
  --render-script "$RENDER_SCRIPT" \
  "${REPORT_CHAT_ARGS[@]}" \
  --summary-out "$TOPIC_DIR/skill_report_summary.json" \
  2>"$TOPIC_DIR/collect_report.stderr")"; then
  KEEP_SESSION_DIR=1
  if [[ "$QUIET_FAILURE" != "1" ]]; then
    echo "error: skill did not create or return a report JSON" >&2
    echo "kept failed session dir: $SESSION_DIR" >&2
    print_agent_diagnostics
    echo "session files:" >&2
    find "$SESSION_DIR" -maxdepth 5 -type f | sort >&2 || true
    cat "$TOPIC_DIR/collect_report.stderr" >&2 || true
  fi
  exit 1
fi

VALIDATION_STDERR="$TOPIC_DIR/validation.stderr"
if ! python3 "$ROOT_DIR/scripts/validate_report.py" \
  --report "$REPORT_JSON" \
  --topic-id "$TOPIC_ID" \
  --run-id "$RUN_ID" \
  --summary-out "$TOPIC_DIR/validation.json" \
  --out-json "$TOPIC_DIR/dragun.json" \
  --out-jsonl "$RUN_JSONL" \
  2>"$VALIDATION_STDERR"; then
  KEEP_SESSION_DIR=1
  if [[ "$QUIET_FAILURE" != "1" ]]; then
    cat "$VALIDATION_STDERR" >&2 || true
    echo "error: report validation failed" >&2
    echo "kept failed session dir: $SESSION_DIR" >&2
    print_agent_diagnostics
  fi
  exit 1
fi
if [[ -s "$VALIDATION_STDERR" && "$QUIET_FAILURE" != "1" ]]; then
  cat "$VALIDATION_STDERR" >&2 || true
fi

echo "$TOPIC_DIR/dragun.json"
