#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID=""
INPUT_FOLDER="$ROOT_DIR/data/runs/report_generation_runs"
OUT_DIR=""
JUDGE_BASE_URL="${JUDGE_BASE_URL:-https://openrouter.ai/api/v1}"
JUDGE_MODEL="${JUDGE_MODEL:-openai/gpt-oss-120b}"
JUDGE_API_KEY_ENV="${JUDGE_API_KEY_ENV:-OPENROUTER_API_KEY}"
JUDGE_REASONING_EFFORT="${JUDGE_REASONING_EFFORT:-high}"
JUDGE_SERVICE_TIER="${JUDGE_SERVICE_TIER:-flex}"

usage() {
  cat <<'EOF'
usage: scripts/score_with_autojudge.sh --run-id ID [options]

Options:
  --input-folder PATH    Folder containing DRAGUN report-generation run files
  --out DIR              Output directory for AutoJudge CSVs and score CSVs
  --judge-base-url URL   OpenAI-compatible base URL
  --judge-model MODEL    Judge model name
  --judge-reasoning-effort EFFORT
                         OpenRouter reasoning effort, or off to omit (default: high)
  --judge-service-tier TIER
                         OpenRouter service_tier, or off to omit (default: flex)
  --api-key-env NAME     Environment variable containing the API key
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --input-folder) INPUT_FOLDER="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --judge-base-url) JUDGE_BASE_URL="$2"; shift 2 ;;
    --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
    --judge-reasoning-effort) JUDGE_REASONING_EFFORT="$2"; shift 2 ;;
    --judge-service-tier) JUDGE_SERVICE_TIER="$2"; shift 2 ;;
    --api-key-env) JUDGE_API_KEY_ENV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "error: --run-id is required" >&2
  exit 2
fi
RUN_ID="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
RUN_SAFE="$(python3 "$ROOT_DIR/scripts/sanitize_id.py" "$RUN_ID")"
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT_DIR/runs/$RUN_SAFE/autojudge"
fi

if [[ "$JUDGE_BASE_URL" == *"openrouter.ai"* && -z "${!JUDGE_API_KEY_ENV:-}" ]]; then
  echo "error: $JUDGE_API_KEY_ENV is required for OpenRouter AutoJudge" >&2
  exit 2
fi
if [[ ! -f "$INPUT_FOLDER/$RUN_ID" ]]; then
  echo "error: expected run file $INPUT_FOLDER/$RUN_ID" >&2
  exit 2
fi

if [[ -d "$ROOT_DIR/.venv" ]]; then
  . "$ROOT_DIR/.venv/bin/activate"
fi

python "$ROOT_DIR/autojudge/auto_judge_openrouter.py" \
  --task auto_report_evaluation \
  --input_folder_path "$INPUT_FOLDER" \
  --output_folder_path "$OUT_DIR" \
  --base-url "$JUDGE_BASE_URL" \
  --model "$JUDGE_MODEL" \
  --reasoning-effort "$JUDGE_REASONING_EFFORT" \
  --service-tier "$JUDGE_SERVICE_TIER" \
  --api-key-env "$JUDGE_API_KEY_ENV" \
  --run-tags "$RUN_ID"

python "$ROOT_DIR/autojudge/score.py" \
  --task report_generation_evaluation \
  --type auto \
  --assessment_input "$OUT_DIR/auto_report_assessments.csv" \
  --output "$OUT_DIR"

python "$ROOT_DIR/scripts/build_leaderboard.py" --run-id "$RUN_ID"

echo "autojudge output: $OUT_DIR"
