# DRAGUN Skill Testbed

This repo benchmarks portable lateral-reading skills and LLM backbones on the TREC 2025 DRAGUN news trustworthiness report task.

The project now has three primary execution options:

1. **Claude Code with default Claude backbones**: use Claude Code as the agent and Anthropic as the model provider.
2. **Codex with default GPT backbones**: use Codex as the agent and the default OpenAI/Codex model provider.
3. **Codex with OpenRouter backbones**: use Codex as the agent and OpenRouter as the provider, so the same skill can be tested with OpenRouter-hosted GPT, Claude, Gemini, GLM, Qwen, and other frontier model families.

The public leaderboard should use the third option so reported rows compare major frontier LLMs through one common agent harness: Codex plus OpenRouter plus the selected lateral-reading skill variant.

## Current Empirical Leaderboard

The current public leaderboard is from a May 25, 2026 DRAGUN Task 2 report-generation run using Codex as the agent, OpenRouter as the generation provider, the default lateral-reading skill at commit `1051e45`, and the AutoJudge system judged by GLM-5.1 through OpenRouter. All rows completed 30/30 valid topics, had a citation URL pass rate of 1.0, and had zero forbidden-source violations.

Rank is based on `auto_supportive_score` (higher is better). `auto_contradictory_score` is included as a contradiction signal (lower is better).

| Rank | Model | Provider | Auto supportive score | Auto contradictory score | Mean report words | Reports |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 1 | `anthropic/claude-opus-4.7` | OpenRouter | 0.4084 | 0.0177 | 600.4 | [reports/claude-opus-4.7](reports/claude-opus-4.7/) |
| 2 | `openai/gpt-5.5` | OpenRouter | 0.3442 | 0.0070 | 399.9 | [reports/gpt-5.5](reports/gpt-5.5/) |
| 3 | `google/gemini-3.1-pro-preview` | OpenRouter | 0.2665 | 0.0076 | 214.9 | [reports/gemini-3.1-pro-preview](reports/gemini-3.1-pro-preview/) |

Detailed artifacts are checked in as [leaderboard CSV](leaderboard/leaderboard.csv), [leaderboard JSON](leaderboard/leaderboard.json), and [public per-article reports](reports/).

Treat this leaderboard as an empirical run result, not as a strict controlled experiment or deterministic conclusion. The setup does not control every component that can affect generation or judging, including OpenRouter model routing and provider behavior, backend batch processing, service-tier scheduling, OpenRouter-provided web search and web fetch behavior, search index freshness, and ordinary nondeterminism in model generation and AutoJudge scoring. The table is useful for comparing these runs under this harness and date, but it should not be read as a stable model-capability ordering.

## Quick Start

```bash
git clone git@github.com:trec-dragun/testbed.git
cd testbed
./scripts/bootstrap.sh
```

Run the default skill with Claude Code and Claude backbones:

```bash
./scripts/launch.sh \
  --agent claude \
  --provider anthropic \
  --model sonnet \
  --run-id claude_code_sonnet_lateral_reading \
  --overwrite
```

Run the default skill with Codex and default GPT backbones:

```bash
./scripts/launch.sh \
  --agent codex \
  --provider openai \
  --model gpt-5.5 \
  --run-id codex_openai_gpt_5_5_lateral_reading \
  --overwrite
```

Run the default skill with Codex and OpenRouter backbones:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/launch.sh \
  --agent codex \
  --provider openrouter \
  --model google/gemini-3.5-flash \
  --run-id codex_openrouter_google_gemini_3_5_flash_lateral_reading \
  --overwrite
```

For a smoke test, add `--limit 1`.

`--agent` may be omitted. The runner infers `claude` for `--provider anthropic` and `codex` for `--provider openai` or `--provider openrouter`.

`--model` may also be omitted. Defaults are `sonnet` for Anthropic, `gpt-5.5` for OpenAI/Codex, and `openai/gpt-5.2` for OpenRouter.

Failed articles are attempted up to five times by default. The batch runner waits 120 seconds after each failed attempt before retrying by default; override with `--max-attempts N`, `RUN_TOPIC_MAX_ATTEMPTS=N`, `--retry-delay-seconds N`, or `RUN_TOPIC_RETRY_DELAY_SECONDS=N`.

For leaderboard runs, refresh the exact OpenRouter model slugs from `https://openrouter.ai/api/v1/models` before launching a batch.

## Skill Variants

Bootstrap clones the default `trec-dragun/lateral-reading-skill` into `skills_under_test/lateral-reading-skill`. To test another skill repo:

```bash
./scripts/launch.sh \
  --skill-repo https://github.com/trec-dragun/lateral-reading-skill.git \
  --agent codex \
  --provider openrouter \
  --model openai/gpt-5.2 \
  --run-id codex_openrouter_openai_gpt_5_2_custom_skill \
  --overwrite
```

To test an already cloned local skill:

```bash
./scripts/launch.sh \
  --skill ./skills_under_test/my-lateral-reading-variant \
  --agent codex \
  --provider openrouter \
  --model anthropic/claude-opus-4.7 \
  --run-id codex_openrouter_claude_opus_4_7_my_variant \
  --overwrite
```

For Claude Code only, if a plugin exposes more than one skill, pass the exact slash command:

```bash
./scripts/launch.sh \
  --skill ./skills_under_test/my-skill \
  --skill-command /my-plugin:my-skill \
  --agent claude \
  --provider anthropic \
  --model sonnet \
  --run-id claude_code_sonnet_my_skill \
  --overwrite
```

Codex loads the first `skills/*/SKILL.md` from the skill repo into an isolated per-run `CODEX_HOME/skills/{skill-name}` and invokes it with `$skill-name`.

## What Setup Downloads

`scripts/bootstrap.sh` creates `.venv`, installs Python dependencies, and downloads or clones:

- `trec-dragun/resources` into `vendor/resources`
- the default skill repo into `skills_under_test/lateral-reading-skill`
- official DRAGUN topics into `data/trec-2025-dragun-topics.jsonl`
- the official DRAGUN package into `data/human_rubrics`, `data/human_assessments`, and related folders
- organizer Task 2 runs into `data/runs/report_generation_runs`

The downloaded data, cloned skill repos, generated runs, and generated reports are gitignored.

## Generation Flow

For each article, `scripts/run_one.sh` creates a fresh temporary workspace, copies the selected skill repo into that workspace, gives the model only anonymous article aliases such as `article_001`, and keeps topic IDs, rubrics, human assessments, official results, and AutoJudge artifacts outside the model-facing workspace.

The prompt starts with either:

```text
/lateral-reading-skill:lateral-reading
```

for Claude Code, or:

```text
Use $lateral-reading for this automated lateral-reading run.
```

for Codex. The runner then adds an automated artifact note and the plaintext article.

The model must create:

```text
reports/lateral-reading/
  target.txt
  report.json
```

The runner renders `report.html` after the session if the skill did not render it. If the agent cannot write files but returns:

```text
<report_json>{"responses":[...]}</report_json>
```

the collector materializes that JSON into `reports/lateral-reading/report.json`.

## Output Contract

`report.json` must be a JSON object with one non-empty `responses` array:

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

Validation enforces:

- one string `text` and one citation list per response
- `http` or `https` citations
- no Markdown fences
- no URL placeholders
- no hidden topic IDs, rubrics, AutoJudge artifacts, human assessments, official result paths, or MS MARCO segment citations

After validation, the wrapper adds the private evaluator metadata:

```json
{
  "metadata": {
    "run_id": "codex_openrouter_google_gemini_3_5_flash_lateral_reading",
    "topic_id": "msmarco_v2.1_doc_04_420132660"
  },
  "responses": []
}
```

The article text shown to the model never contains the topic ID.

## Agent Details

### Claude Code / Anthropic

Claude Code runs from the temporary `work/` directory with:

- `--no-session-persistence`
- `--setting-sources project`
- `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`
- `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`
- default tools: `WebFetch,WebSearch,Read,Write`

Claude Code sessions default to `--effort high`. Override with `--effort low`, `--effort medium`, `--effort xhigh`, or `--effort max` only for a deliberate ablation.

### Codex / OpenAI

Codex runs with a fresh isolated `CODEX_HOME` under `tmp/sessions/` and the selected skill installed under `CODEX_HOME/skills`. The runner copies `auth.json` from the source Codex home when it exists, so normal Codex login can be reused without loading the user's full Codex history, memories, plugins, or global skills.

Default Codex controls:

```bash
CODEX_REASONING_EFFORT=high
CODEX_APPROVAL_POLICY=never
CODEX_SANDBOX=workspace-write
CODEX_WEB_SEARCH=1
```

For OpenAI-provider Codex runs, `CODEX_WEB_SEARCH=1` enables Codex native web search through `tools.web_search`.

### Codex / OpenRouter

Codex/OpenRouter uses a generated `config.toml` in the isolated `CODEX_HOME`:

```toml
model_provider = "openrouter"

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
requires_openai_auth = false
```

When `OPENROUTER_SERVICE_TIER` or OpenRouter server tools are enabled, the runner starts a local per-session proxy and points Codex at that proxy. The proxy injects `service_tier`, `openrouter:web_search`, and `openrouter:web_fetch` into outbound Responses requests.

OpenRouter generation defaults:

```bash
OPENROUTER_SERVICE_TIER=auto
OPENROUTER_WEB_SEARCH=1
OPENROUTER_WEB_SEARCH_ENGINE=auto
OPENROUTER_WEB_SEARCH_MAX_RESULTS=5
OPENROUTER_WEB_SEARCH_MAX_TOTAL_RESULTS=20
OPENROUTER_WEB_FETCH=1
OPENROUTER_WEB_FETCH_ENGINE=auto
OPENROUTER_WEB_FETCH_MAX_USES=20
OPENROUTER_WEB_FETCH_MAX_CONTENT_TOKENS=100000
```

In `auto` service-tier mode, the runner requests `flex` only for `openai/*` and `google/*` model slugs. Other OpenRouter model families are sent without a service-tier field unless you explicitly set `OPENROUTER_SERVICE_TIER`.

## Run Artifacts

After a completed launch:

```text
runs/{run_id}/
  dragun_task2.jsonl
  manifest.json
  private_topic_ids/
  topic_map.jsonl
  topics/article_001/
    input.txt
    transcript_audit.json
    validation.json
    dragun.json
    skill_report/
      target.txt
      report.json
      report.html
```

Claude runs also include `claude_stream.jsonl`, `claude_raw.txt`, and `trajectory_summary.json`.

Codex runs include `codex_stream.jsonl`, `codex_raw.txt`, `codex_last_message.txt`, `codex_config.toml`, and `codex_trajectory_summary.json`.

Public report copies are written to:

```text
reports/{run_id}/article_001/report.html
```

AutoJudge input is copied to:

```text
data/runs/report_generation_runs/{run_id}
```

## AutoJudge and Leaderboard

Score a completed run:

```bash
export OPENROUTER_API_KEY="sk-or-..."
./scripts/score_with_autojudge.sh \
  --run-id codex_openrouter_google_gemini_3_5_flash_lateral_reading \
  --judge-base-url https://openrouter.ai/api/v1 \
  --judge-model openai/gpt-oss-120b
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

For public rankings, use Codex/OpenRouter rows only. Claude Code/Anthropic and Codex/OpenAI rows are local development baselines for testing agent behavior, skill variants, and prompt regressions.

## Important Files

- `scripts/bootstrap.sh`: one-shot setup
- `scripts/launch.sh`: setup plus batch generation
- `scripts/run_batch.sh`: all selected articles
- `scripts/run_one.sh`: one isolated agent session for one article
- `scripts/check_openrouter_key.sh`: OpenRouter API key preflight
- `scripts/openrouter_service_tier_proxy.py`: OpenRouter request proxy for `service_tier`, server-tool injection, and Codex-compatible model lists
- `scripts/audit_session_exposure.py`: checks visible leakage risk before a batch
- `scripts/audit_transcript.py`: scans agent output for forbidden evaluation-artifact terms
- `scripts/collect_skill_report.py`: copies file output or materializes sentinel-wrapped JSON
- `scripts/resolve_skill_command.py`: resolves Claude Code slash commands
- `scripts/resolve_skill_name.py`: resolves Codex skill names
- `scripts/validate_report.py`: schema, citation, and leakage validation
- `scripts/score_with_autojudge.sh`: AutoJudge plus score aggregation
- `scripts/build_leaderboard.py`: leaderboard row generation
