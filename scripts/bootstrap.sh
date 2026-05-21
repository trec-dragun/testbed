#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESOURCES_REPO_URL="${RESOURCES_REPO_URL:-https://github.com/trec-dragun/resources.git}"
DEFAULT_SKILL_REPO_URL="${DEFAULT_SKILL_REPO_URL:-https://github.com/trec-dragun/lateral-reading-skill.git}"
TOPICS_URL="${TOPICS_URL:-https://trec.nist.gov/data/dragun/trec-2025-dragun-topics.jsonl}"
PACKAGE_URL="${PACKAGE_URL:-https://trec.nist.gov/data/dragun/DRAGUN.zip}"

mkdir -p data/runs/report_generation_runs skills_under_test vendor tmp reports runs leaderboard

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

if [[ ! -d vendor/resources/.git ]]; then
  git clone --depth 1 "$RESOURCES_REPO_URL" vendor/resources
else
  git -C vendor/resources pull --ff-only
fi

if [[ ! -d skills_under_test/lateral-reading-skill/.git ]]; then
  git clone --depth 1 "$DEFAULT_SKILL_REPO_URL" skills_under_test/lateral-reading-skill
else
  git -C skills_under_test/lateral-reading-skill pull --ff-only
fi

if [[ ! -s data/trec-2025-dragun-topics.jsonl ]]; then
  if ! curl -fL "$TOPICS_URL" -o data/trec-2025-dragun-topics.jsonl; then
    rm -f data/trec-2025-dragun-topics.jsonl
    echo "warning: direct topics download failed; trying the full DRAGUN package" >&2
  fi
fi

if [[ ! -s data/trec-2025-dragun-topics.jsonl || ! -d data/human_rubrics || ! -d data/human_assessments ]]; then
  curl -fL "$PACKAGE_URL" -o tmp/DRAGUN.zip
  python scripts/import_dragun_package.py --zip tmp/DRAGUN.zip --out data --work tmp/dragun_package_extract
fi

if [[ -d vendor/resources/data/runs/report_generation_runs ]]; then
  cp -n vendor/resources/data/runs/report_generation_runs/* data/runs/report_generation_runs/ 2>/dev/null || true
fi

python scripts/list_topics.py --topics data/trec-2025-dragun-topics.jsonl >/dev/null

echo "Bootstrap complete."
echo "Default skill: skills_under_test/lateral-reading-skill"
echo "Topics: data/trec-2025-dragun-topics.jsonl"
echo "AutoJudge data: data/human_rubrics and data/human_assessments"
