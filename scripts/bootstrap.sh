#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESOURCES_REPO_URL="${RESOURCES_REPO_URL:-https://github.com/trec-dragun/resources.git}"
DEFAULT_SKILL_REPO_URL="${DEFAULT_SKILL_REPO_URL:-https://github.com/trec-dragun/lateral-reading-skill.git}"
TOPICS_URL="${TOPICS_URL:-https://trec.nist.gov/data/dragun/trec-2025-dragun-topics.jsonl}"
PACKAGE_URL="${PACKAGE_URL:-https://trec.nist.gov/data/dragun/DRAGUN.zip}"

mkdir -p data/runs/report_generation_runs skills_under_test vendor tmp reports runs leaderboard
BOOTSTRAP_LOG_DIR="${BOOTSTRAP_LOG_DIR:-tmp/bootstrap_logs}"
mkdir -p "$BOOTSTRAP_LOG_DIR"

run_quiet() {
  local label="$1"
  shift
  local log
  log="$(mktemp "$BOOTSTRAP_LOG_DIR/step.XXXXXX.log")"
  printf '%s... ' "$label"
  if "$@" >"$log" 2>&1; then
    echo "ok"
  else
    echo "failed"
    echo "Log: $log" >&2
    cat "$log" >&2
    exit 1
  fi
}

if [[ ! -d .venv ]]; then
  run_quiet "Creating Python virtual environment" python3 -m venv .venv
fi
. .venv/bin/activate
run_quiet "Checking Python dependencies" python -m pip install -q --upgrade pip
run_quiet "Installing Python requirements" python -m pip install -q -r requirements.txt

if [[ ! -d vendor/resources/.git ]]; then
  run_quiet "Cloning trec-dragun/resources" git clone --quiet --depth 1 "$RESOURCES_REPO_URL" vendor/resources
else
  run_quiet "Updating trec-dragun/resources" git -C vendor/resources pull --quiet --ff-only
fi

if [[ ! -d skills_under_test/lateral-reading-skill/.git ]]; then
  run_quiet "Cloning default lateral-reading skill" git clone --quiet --depth 1 "$DEFAULT_SKILL_REPO_URL" skills_under_test/lateral-reading-skill
else
  run_quiet "Updating default lateral-reading skill" git -C skills_under_test/lateral-reading-skill pull --quiet --ff-only
fi

if [[ ! -s data/trec-2025-dragun-topics.jsonl ]]; then
  printf 'Downloading topics... '
  if curl -fsSL "$TOPICS_URL" -o data/trec-2025-dragun-topics.jsonl >"$BOOTSTRAP_LOG_DIR/topics.log" 2>&1; then
    echo "ok"
  else
    echo "direct download failed; trying package"
    rm -f data/trec-2025-dragun-topics.jsonl
  fi
fi

if [[ ! -s data/trec-2025-dragun-topics.jsonl || ! -d data/human_rubrics || ! -d data/human_assessments ]]; then
  run_quiet "Downloading DRAGUN package" curl -fsSL "$PACKAGE_URL" -o tmp/DRAGUN.zip
  run_quiet "Importing DRAGUN package" python scripts/import_dragun_package.py --zip tmp/DRAGUN.zip --out data --work tmp/dragun_package_extract
fi

if [[ -d vendor/resources/data/runs/report_generation_runs ]]; then
  cp -n vendor/resources/data/runs/report_generation_runs/* data/runs/report_generation_runs/ 2>/dev/null || true
fi

run_quiet "Validating topics file" python scripts/list_topics.py --topics data/trec-2025-dragun-topics.jsonl

echo "Bootstrap complete."
echo "Default skill: skills_under_test/lateral-reading-skill"
echo "Topics: data/trec-2025-dragun-topics.jsonl"
echo "AutoJudge data: data/human_rubrics and data/human_assessments"
