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

Run the default lateral-reading skill with your normal Claude Code account. This is the recommended path for lateral-reading generation because it keeps Claude Code's native `WebSearch` tool on the Anthropic-backed execution path:

```bash
./scripts/launch.sh \
  --provider anthropic \
  --model sonnet \
  --run-id anthropic_sonnet_lateral_reading \
  --overwrite
```

Run through OpenRouter with OpenRouter's server-side web search and fetch. For OpenRouter generation, the runner removes Claude Code's native `WebSearch` and `WebFetch` tools from the default tool set and injects OpenRouter's `openrouter:web_search` and `openrouter:web_fetch` server tools into the OpenRouter request:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/launch.sh \
  --provider openrouter \
  --model openai/gpt-5.2 \
  --run-id openrouter_openai_gpt_5_2_lateral_reading \
  --overwrite
```

Set `OPENROUTER_WEB_SEARCH=0` or `OPENROUTER_WEB_FETCH=0` to disable either OpenRouter server tool. To intentionally test whether OpenRouter can handle Claude Code's native web tools, set `CLAUDE_TOOLS="WebFetch,WebSearch,Read,Write"` plus `OPENROUTER_ALLOW_WEBSEARCH=1` and `OPENROUTER_ALLOW_WEBFETCH=1`.

Run another skill repo:

```bash
./scripts/launch.sh \
  --skill-repo https://github.com/trec-dragun/lateral-reading-skill.git \
  --provider anthropic \
  --model sonnet \
  --run-id anthropic_sonnet_custom_skill \
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

For every run, the harness uses a fresh temp workspace plus `--no-session-persistence --setting-sources project`. It also exports `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` and `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`, so Claude Code does not read or write auto-memory files or load user/project `CLAUDE.md` memory. `--bare` is not enabled by default because it can remove the normal Claude Code tool runtime needed by skills; set `CLAUDE_BARE=1` only for an explicit isolation ablation.

Claude Code sessions default to `--effort high` for consistent reasoning depth across tested backbones. Override with `--effort low`, `--effort medium`, `--effort xhigh`, or `--effort max` only when intentionally running an ablation.

For OpenRouter runs, the wrapper first checks `OPENROUTER_API_KEY` against OpenRouter's `/api/v1/key` endpoint, then points Claude Code at OpenRouter's Anthropic-compatible endpoint with `ANTHROPIC_AUTH_TOKEN`, an explicitly empty `ANTHROPIC_API_KEY`, and an explicit `Authorization: Bearer ...` entry in `ANTHROPIC_CUSTOM_HEADERS`. It also sets Claude Code's model variables (`ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_*_MODEL`, and `CLAUDE_CODE_SUBAGENT_MODEL`) to the requested model, and sets `CLAUDE_CODE_EFFORT_LEVEL` to the requested effort. Claude Code over OpenRouter is still provider-sensitive: some non-Anthropic backbones may fail to use client-side Claude Code tools, close streams early, or return no final output. For web retrieval, the OpenRouter path now avoids Claude Code's native `WebSearch` and `WebFetch` by default and uses OpenRouter's `openrouter:web_search` and `openrouter:web_fetch` server tools instead. The runner does not synthesize a report or silently recover from failures.

OpenRouter generation runs default to `OPENROUTER_SERVICE_TIER=auto`. In auto mode, the runner requests `flex` only for `openai/*` and `google/*` model slugs, where OpenRouter advertises service-tier support, and sends Anthropic and other models without a service-tier field. Claude Code does not expose OpenRouter's top-level `service_tier` or server-tool request fields, so the runner starts a local per-session proxy whenever it needs to add `service_tier` or OpenRouter web tools to the outbound request. Set `OPENROUTER_SERVICE_TIER=off` to disable service-tier injection, `OPENROUTER_SERVICE_TIER=flex` to force flex, or `OPENROUTER_SERVICE_TIER=priority` to request priority.

OpenRouter web search defaults to:

```bash
OPENROUTER_WEB_SEARCH=1
OPENROUTER_WEB_SEARCH_ENGINE=auto
OPENROUTER_WEB_SEARCH_MAX_RESULTS=5
OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS=20
OPENROUTER_WEB_FETCH=1
OPENROUTER_WEB_FETCH_ENGINE=auto
OPENROUTER_WEB_FETCH_MAX_USES=20
OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS=100000
```

Optional controls are `OPENROUTER_WEB_SEARCH_CONTEXT_SIZE`, `OPENROUTER_WEB_SEARCH_ALLOWED_DOMAINS`, `OPENROUTER_WEB_SEARCH_EXCLUDED_DOMAINS`, `OPENROUTER_WEB_FETCH_ALLOWED_DOMAINS`, and `OPENROUTER_WEB_FETCH_BLOCKED_DOMAINS`. Domain lists are comma-separated.

Failed topic runs keep the temporary session folder and write `claude_stderr.log` plus `claude_exit_code.txt` under the topic artifact directory; set `CLAUDE_DEBUG_LOG=1` to also save Claude Code debug logs. The debug file path given to Claude Code is inside the anonymous temporary session and copied back afterward, so hidden topic IDs are not exposed through debug CLI arguments. Set `OPENROUTER_PREFLIGHT=0` only if you need to skip the key check.

Each article is attempted up to three times by default. A failed attempt is moved to `runs/{run_id}/failed_attempts/article_001/attempt_01/`, then the article is rerun in a new temporary session and clean topic artifact directory. Attempts 1 and 2 print only a compact failure/retry line; if the final attempt fails, the runner prints the normal diagnostics and points to the failed-attempt log directory. Override with `--max-attempts N` or `RUN_TOPIC_MAX_ATTEMPTS=N`.

Trajectory tracing is enabled by default. Claude Code stdout uses `--output-format stream-json --verbose`, and the runner saves `claude_stream.jsonl`, `trajectory_summary.json`, and a reconstructed visible `claude_raw.txt` under each topic artifact directory. The trajectory summary lists Claude Code tool calls, native `WebSearch` queries, native `WebFetch` URLs, file reads/writes, and the final visible chat text length. OpenRouter server-side search and fetch calls are executed inside OpenRouter, so they do not appear as Claude Code `WebSearch` or `WebFetch` tool calls. The trace does not recover private chain-of-thought; any `thinking` blocks are only counted. Set `CLAUDE_TRACE=0` to disable tracing for smaller artifacts.

## Claude Code Tools

For Anthropic-provider runs, the launch scripts expose a small Claude Code tool set:

- `WebFetch`
- `WebSearch`
- `Read`
- `Write`

For OpenRouter-provider runs, the default Claude Code tool set is:

- `Read`
- `Write`

The OpenRouter request proxy adds `{ "type": "openrouter:web_search" }` and `{ "type": "openrouter:web_fetch" }` to the request body so web retrieval is performed by OpenRouter server tools rather than Claude Code's native web tools.

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
    "run_id": "anthropic_sonnet_lateral_reading",
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
    claude_stream.jsonl
    claude_stderr.log
    claude_exit_code.txt
    trajectory_summary.json
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
  --run-id anthropic_sonnet_lateral_reading \
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

The per-topic and per-run score CSVs keep the original `supportive_score` and `contradictory_score` columns. They also include `normalized_supportive_score` and `normalized_contradictory_score`, computed as the corresponding original score divided by the report word count, plus report word-count columns for context.

`scripts/build_leaderboard.py` updates:

```text
leaderboard/leaderboard.csv
leaderboard/leaderboard.json
```

During generation, `scripts/run_batch.sh` prints per-article start and completion lines with elapsed time and an ETA based on completed articles.

## Testing Multiple Backbones

Use explicit run IDs that encode provider, model, and skill. Keep an Anthropic run as the native Claude Code baseline, then compare OpenRouter backbones with OpenRouter server-side search enabled:

```bash
./scripts/launch.sh --provider anthropic --model sonnet --run-id anthropic_sonnet_lr --overwrite
./scripts/launch.sh --provider openrouter --model openai/gpt-5.2 --run-id openrouter_gpt_5_2_lr_or_search --overwrite
./scripts/launch.sh --provider openrouter --model google/gemini-3-pro --run-id openrouter_gemini_3_pro_lr_or_search --limit 1 --overwrite
```

The leaderboard measures the full stack: Claude Code, the skill prompt and scripts, tool use, web retrieval behavior, provider compatibility, and the model backbone. It is not a pure base-model benchmark.

## Important Files

- `scripts/bootstrap.sh`: one-shot setup
- `scripts/launch.sh`: setup plus all-topic generation
- `scripts/run_one.sh`: one isolated Claude Code session for one article
- `scripts/run_batch.sh`: all selected articles
- `scripts/check_openrouter_key.sh`: fail-fast OpenRouter API key preflight
- `scripts/openrouter_service_tier_proxy.py`: local OpenRouter request proxy for `service_tier` and OpenRouter server-tool injection
- `scripts/audit_session_exposure.py`: checks session exposure strings and the default tool set
- `scripts/audit_transcript.py`: scans Claude output for forbidden evaluation-artifact terms
- `scripts/collect_skill_report.py`: copies the skill-produced `report.json` and `report.html`
- `scripts/resolve_skill_command.py`: resolves the slash command used to invoke the skill
- `scripts/resolve_skill_file.py`: resolves the skill instruction file for non-interactive runs
- `scripts/validate_report.py`: schema, citation, and leakage validation
- `scripts/score_with_autojudge.sh`: AutoJudge plus scoring
- `autojudge/auto_judge_openrouter.py`: OpenRouter-compatible report judge
