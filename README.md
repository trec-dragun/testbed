# DRAGUN Skill Testbed

This repo benchmarks Claude Code skills and LLM backbones on the TREC 2025 DRAGUN news trustworthiness report task.

The intended workflow is:

1. Clone this testbed.
2. Run one setup command to download dependencies, the DRAGUN evaluation assets, organizer example runs, and the default `trec-dragun/lateral-reading-skill`.
3. Launch one Claude Code session per article.
4. Collect each skill-produced `report.json` and `report.html`, then wrap `report.json` into evaluator JSONL.
5. Score report coverage with an OpenRouter-compatible AutoJudge.
6. Publish leaderboard rows from the generated run metadata and scores.

## Quick Start

```bash
git clone git@github.com:trec-dragun/testbed.git
cd testbed
./scripts/bootstrap.sh
```

Run the default lateral-reading skill with your normal Claude Code account:

```bash
./scripts/launch.sh \
  --provider anthropic \
  --model sonnet \
  --run-id anthropic_sonnet_lateral_reading \
  --overwrite
```

Run through OpenRouter:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/launch.sh \
  --provider openrouter \
  --model openai/gpt-5.5 \
  --run-id openrouter_openai_gpt_5_5_lateral_reading \
  --overwrite
```

Run another skill repo:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/launch.sh \
  --skill-repo https://github.com/trec-dragun/lateral-reading-skill.git \
  --provider openrouter \
  --model openai/gpt-5.5 \
  --run-id openrouter_gpt_5_5_custom_skill \
  --overwrite
```

For a smoke test, add `--limit 1`.

## What Setup Downloads

`scripts/bootstrap.sh` creates `.venv`, installs Python dependencies, and downloads or clones:

- `trec-dragun/resources` into `vendor/resources`
- the default skill repo into `skills_under_test/lateral-reading-skill`
- official DRAGUN topics into `data/trec-2025-dragun-topics.jsonl`
- the official DRAGUN package into `data/human_rubrics`, `data/human_assessments`, and related folders
- organizer Task 2 runs into `data/runs/report_generation_runs`

The data and cloned repos are gitignored.

If the NIST package URL is temporarily unavailable, rerun `./scripts/bootstrap.sh` later or manually place the DRAGUN package contents into the expected `data/` layout.

Setup output is intentionally concise. Routine `pip`, `git pull`, and download details are written to `tmp/bootstrap_logs/` and shown only when a step fails.

## Generation Isolation

The model is never launched from this repo. For each article, `scripts/run_one.sh` creates a fresh temporary workspace and runs Claude Code from the copied skill repo.

The only task input is plaintext in the user prompt:

```text
Title: ...
URL: ...
Heading: ...

Article body...
```

The wrapper keeps rubrics, AutoJudge files, human assessments, official results, the full topics file, and topic IDs outside Claude Code's working directory. It adds `metadata.topic_id` only after collecting the skill's `report.json`.

Before a batch starts, `scripts/run_batch.sh` runs `scripts/audit_session_exposure.py --skill ...`. This fails fast if the session launcher, default tool allowlist, or selected skill repo contains explicit evaluation identifiers such as DRAGUN, TREC, AutoJudge, human rubric paths, MS MARCO topic IDs, or similar leakage terms.

For OpenRouter or Anthropic API-key runs, the harness uses `claude --bare --no-session-persistence`, which disables auto memory and session persistence. For a normal Claude Code subscription account, Claude Code currently cannot use `--bare` because bare mode does not read OAuth/keychain credentials; the harness then uses a fresh temp workspace plus `--no-session-persistence --setting-sources project`.

Claude Code sessions default to `--effort high` for consistent reasoning depth across tested backbones. Override with `--effort low`, `--effort medium`, `--effort xhigh`, or `--effort max` only when intentionally running an ablation.

For OpenRouter runs, the wrapper sets Claude Code's Anthropic-compatible model variables (`ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`) to the requested model, and sets `CLAUDE_CODE_EFFORT_LEVEL` to the requested effort. Claude Code over OpenRouter is still provider-sensitive: some non-Anthropic backbones may fail to use tools or may return no final output. Failed topic runs keep the temporary session folder and write `claude_stderr.log` plus `claude_exit_code.txt` under the topic artifact directory; set `CLAUDE_DEBUG_LOG=1` to also save Claude Code debug logs.

## Claude Code Permissions

The launch scripts grant the tested skill only the tools needed inside the temporary session workspace:

- `WebFetch`
- `WebSearch`
- `Read`
- `Write`
- `Edit`
- `Bash(mkdir -p reports*)`
- `Bash(python3 skills/*/scripts/render_report_html.py *)`
- `Bash(python skills/*/scripts/render_report_html.py *)`
- `Bash(python3 skills/*/scripts/validate_report.py *)`
- `Bash(python skills/*/scripts/validate_report.py *)`

This avoids generic `python`, `curl`, or shell access that could inspect files outside the session. The default permission mode is `auto`, so users should not need to approve each fetch, file write, folder creation, or render command. Override only if you understand the leakage risk:

```bash
export CLAUDE_PERMISSION_MODE=default
export ALLOWED_TOOLS="WebFetch,WebSearch,Read,Write,Edit,Bash(mkdir -p reports*)"
```

## Output Contract

The skill should write its normal output folder:

```text
reports/lateral-reading-YYYYMMDD-HHMMSS/
  target.txt
  report.json
  report.html
```

`report.json` must contain the skill's sentence-level response JSON:

```json
{
  "responses": [
    {
      "text": "One complete sentence.",
      "citations": ["https://example.com/source"]
    }
  ]
}
```

The wrapper copies the skill folder to `reports/{run_id}/{topic_id}/` and wraps `report.json` into evaluator JSONL:

```json
{
  "metadata": {
    "run_id": "openrouter_openai_gpt_5_5_lateral_reading",
    "topic_id": "msmarco_v2.1_doc_04_420132660"
  },
  "responses": [
    {
      "text": "One complete sentence.",
      "citations": ["https://example.com/source"]
    }
  ]
}
```

Validation enforces:

- non-empty `responses`
- one string `text` and one citation list per response
- `http` or `https` citations
- no Markdown fences
- no URL placeholders
- no hidden topic IDs, rubrics, AutoJudge artifacts, human assessments, official result paths, or MS MARCO segment citations

## Run Artifacts

After a full launch, expect:

```text
runs/{run_id}/
  dragun_task2.jsonl
  manifest.json
  topics/{topic_id}/
    claude_raw.json
    claude_stderr.log
    claude_exit_code.txt
    transcript_audit.json
    input.txt
    skill_report/
      target.txt
      report.json
      report.html
    skill_report_summary.json
    validation.json
    dragun.json

data/runs/report_generation_runs/{run_id}
reports/{run_id}/{topic_id}/report.html
```

The `data/runs/report_generation_runs/{run_id}` file is the AutoJudge input.

## AutoJudge

This repo includes `autojudge/auto_judge_openrouter.py`, derived from `trec-dragun/resources`. The modification is deliberately small: the report judge endpoint, model, and API key are configurable for OpenRouter or any OpenAI-compatible service.

OpenRouter AutoJudge calls default to `reasoning.effort=high`, passed through the OpenAI SDK as `extra_body={"reasoning": {"effort": "high"}}`. Override with `--judge-reasoning-effort` or `JUDGE_REASONING_EFFORT`; use `--judge-reasoning-effort off` if the judge endpoint does not support OpenRouter's reasoning field.

Score a completed run:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/score_with_autojudge.sh \
  --run-id openrouter_openai_gpt_5_5_lateral_reading \
  --judge-base-url https://openrouter.ai/api/v1 \
  --judge-model openai/gpt-oss-120b
```

For a local vLLM judge:

```bash
./scripts/score_with_autojudge.sh \
  --run-id local_test \
  --judge-base-url http://localhost:8000/v1 \
  --judge-model openai/gpt-oss-120b \
  --api-key-env EMPTY_API_KEY
```

If the local endpoint ignores API keys:

```bash
export EMPTY_API_KEY=EMPTY
```

AutoJudge writes:

```text
runs/{run_id}/autojudge/
  auto_report_assessments.csv
  auto_report_generation_per_topic_results.csv
  auto_report_generation_per_run_results.csv
```

`scripts/build_leaderboard.py` updates:

```text
leaderboard/leaderboard.csv
leaderboard/leaderboard.json
```

During generation, `scripts/run_batch.sh` prints per-article start and completion lines with elapsed time and an ETA based on completed articles.

## Testing Multiple Backbones

Use explicit run IDs that encode provider, model, and skill:

```bash
./scripts/launch.sh --provider openrouter --model anthropic/claude-opus-4.7 --run-id openrouter_claude_opus_4_7_lr --overwrite
./scripts/launch.sh --provider openrouter --model openai/gpt-5.5 --run-id openrouter_gpt_5_5_lr --overwrite
./scripts/launch.sh --provider openrouter --model google/gemini-3-pro --run-id openrouter_gemini_3_pro_lr --overwrite
```

The leaderboard measures the full stack: Claude Code, the skill prompt and scripts, tool use, web retrieval behavior, provider compatibility, and the model backbone. It is not a pure base-model benchmark.

## Important Files

- `scripts/bootstrap.sh`: one-shot setup
- `scripts/launch.sh`: setup plus all-topic generation
- `scripts/run_one.sh`: one isolated Claude Code session for one article
- `scripts/run_batch.sh`: all selected articles
- `scripts/audit_session_exposure.py`: checks session exposure strings and broad tool permissions
- `scripts/audit_transcript.py`: scans Claude output for forbidden evaluation-artifact terms
- `scripts/collect_skill_report.py`: copies the skill-produced `report.json` and `report.html`
- `scripts/resolve_skill_file.py`: resolves the skill instruction file for non-interactive runs
- `scripts/validate_report.py`: schema, citation, and leakage validation
- `scripts/score_with_autojudge.sh`: AutoJudge plus scoring
- `autojudge/auto_judge_openrouter.py`: OpenRouter-compatible report judge
