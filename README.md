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

If a custom plugin exposes more than one skill, pass the exact slash command:

```bash
./scripts/launch.sh \
  --skill ./skills_under_test/my-skill \
  --skill-command /my-plugin:my-skill \
  --provider anthropic \
  --model sonnet \
  --run-id anthropic_sonnet_my_skill \
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

## Generation Flow

The model is never launched from this repo. For each article, `scripts/run_one.sh` creates a fresh temporary workspace, copies the skill repo into it, and runs Claude Code from that temporary `work/` directory.

The user prompt has exactly one skill invocation followed by the plaintext article:

```text
/lateral-reading-skill:lateral-reading

Title: ...
URL: ...
Heading: ...

Article body...
```

The slash command is resolved from `.claude-plugin/plugin.json` plus `skills/*/SKILL.md`, or set explicitly with `--skill-command`. The article text itself contains no `docid`.

The wrapper keeps rubrics, AutoJudge files, human assessments, official results, the full topics file, and topic IDs outside Claude Code's working directory. Claude-facing artifact paths and progress logs use anonymous aliases such as `article_001`; the private `runs/{run_id}/topic_map.jsonl` maps aliases back to topic IDs after generation. The wrapper adds `metadata.topic_id` only after collecting the skill's `report.json`.

Before a batch starts, `scripts/run_batch.sh` runs `scripts/audit_session_exposure.py --skill ...`. This fails fast if the session launcher, default tool set, or selected skill repo contains explicit evaluation identifiers such as DRAGUN, TREC, AutoJudge, human rubric paths, MS MARCO topic IDs, or similar leakage terms.

For OpenRouter or Anthropic API-key runs, the harness uses `claude --bare --no-session-persistence`, which disables auto memory and session persistence. For a normal Claude Code subscription account, Claude Code currently cannot use `--bare` because bare mode does not read OAuth/keychain credentials; the harness then uses a fresh temp workspace plus `--no-session-persistence --setting-sources project`.

Claude Code sessions default to `--effort high` for consistent reasoning depth across tested backbones. Override with `--effort low`, `--effort medium`, `--effort xhigh`, or `--effort max` only when intentionally running an ablation.

For OpenRouter runs, the wrapper first checks `OPENROUTER_API_KEY` against OpenRouter's `/api/v1/key` endpoint, then points Claude Code at OpenRouter's Anthropic-compatible endpoint with `ANTHROPIC_AUTH_TOKEN`, an explicitly empty `ANTHROPIC_API_KEY`, and an explicit `Authorization: Bearer ...` entry in `ANTHROPIC_CUSTOM_HEADERS`. It also sets Claude Code's model variables (`ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`) to the requested model, and sets `CLAUDE_CODE_EFFORT_LEVEL` to the requested effort. Claude Code over OpenRouter is still provider-sensitive: some non-Anthropic backbones may fail to use tools, close streams early, or return no final output. The runner does not synthesize a report or silently recover from those failures.

OpenRouter generation runs default to `OPENROUTER_SERVICE_TIER=flex` for lower cost when the upstream supports service tiers. Claude Code does not expose OpenRouter's top-level `service_tier` request field, so the runner starts a local per-session proxy that injects it before forwarding to OpenRouter. Set `OPENROUTER_SERVICE_TIER=off` to disable, or `OPENROUTER_SERVICE_TIER=priority` to request priority.

Failed topic runs keep the temporary session folder and write `claude_stderr.log` plus `claude_exit_code.txt` under the topic artifact directory; set `CLAUDE_DEBUG_LOG=1` to also save Claude Code debug logs. The debug file path given to Claude Code is inside the anonymous temporary session and copied back afterward, so hidden topic IDs are not exposed through debug CLI arguments. Set `OPENROUTER_PREFLIGHT=0` only if you need to skip the key check.

## Claude Code Tools

The launch scripts expose a small Claude Code tool set:

- `WebFetch`
- `WebSearch`
- `Read`
- `Write`

Claude Code runs from a fresh temporary `work/` directory containing only the copied skill repo. The wrapper keeps topic IDs, rubrics, AutoJudge files, and official results outside that workspace and does not reference their paths in the prompt.

`Bash`, `Edit`, `Glob`, `Grep`, and `LS` are not in the default tool set. The same tool set is passed to both `--tools` and `--allowed-tools`, so noninteractive runs can fetch, read skill references, and write report files without stopping for approval. The tested model should write `reports/**/report.json`; the wrapper validates `report.json` and renders `report.html` with the skill's own render script after Claude exits.

Runs default to permission mode `acceptEdits` so noninteractive sessions do not wait for approval prompts. Override only if you understand the leakage risk:

```bash
export CLAUDE_PERMISSION_MODE=auto
export CLAUDE_TOOLS="WebFetch,WebSearch,Read,Write"
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

The wrapper copies the skill folder to anonymous public paths such as `reports/{run_id}/article_001/` and wraps `report.json` into evaluator JSONL. If the skill does not create `reports/**/report.json`, the topic fails. Claude stdout is saved for debugging, but it is never parsed into a replacement report.

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
  private_topic_ids/
  topic_map.jsonl
  topics/article_001/
    claude_raw.txt
    claude_stderr.log
    claude_exit_code.txt
    transcript_audit.json
    debug_audit.json
    input.txt
    skill_report/
      target.txt
      report.json
      report.html
    skill_report_summary.json
    validation.json
    dragun.json

data/runs/report_generation_runs/{run_id}
reports/{run_id}/article_001/report.html
```

The `data/runs/report_generation_runs/{run_id}` file is the AutoJudge input.

## AutoJudge

This repo includes `autojudge/auto_judge_openrouter.py`, derived from `trec-dragun/resources`. The modification is deliberately small: the report judge endpoint, model, and API key are configurable for OpenRouter or any OpenAI-compatible service.

OpenRouter AutoJudge calls default to `reasoning.effort=high` and `service_tier=flex`, passed through the OpenAI SDK `extra_body`. Override with `--judge-reasoning-effort` / `JUDGE_REASONING_EFFORT` and `--judge-service-tier` / `JUDGE_SERVICE_TIER`; use `off` if the judge endpoint does not support a field.

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
- `scripts/check_openrouter_key.sh`: fail-fast OpenRouter API key preflight
- `scripts/audit_session_exposure.py`: checks session exposure strings and the default tool set
- `scripts/audit_transcript.py`: scans Claude output for forbidden evaluation-artifact terms
- `scripts/collect_skill_report.py`: copies the skill-produced `report.json` and `report.html`
- `scripts/resolve_skill_command.py`: resolves the slash command used to invoke the skill
- `scripts/resolve_skill_file.py`: resolves the skill instruction file for non-interactive runs
- `scripts/validate_report.py`: schema, citation, and leakage validation
- `scripts/score_with_autojudge.sh`: AutoJudge plus scoring
- `autojudge/auto_judge_openrouter.py`: OpenRouter-compatible report judge
