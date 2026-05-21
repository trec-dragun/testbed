#!/usr/bin/env python3
"""DRAGUN report AutoJudge with OpenAI-compatible endpoint configuration.

This is derived from trec-dragun/resources:auto_judge/auto_judge.py and keeps
the Task 2 report-evaluation behavior, with minimal changes:

- endpoint, model, and API key are CLI/env configurable
- OpenRouter's /api/v1 endpoint works without editing source code
- optional --run-tags filters target runs while keeping organizer few-shot runs
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
from pathlib import Path
from typing import Any, Literal

import pandas as pd
from pydantic import BaseModel
from tqdm import tqdm


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
DATA_DIR = REPO_DIR / "data"
REPORT_ORGANIZER_RUNS = ["organizer-gpt-oss-t2", "dragun-organizers-starter-kit-task-2"]


class ReportAnswerAssessment(BaseModel):
    answer_id: str
    rationale: str
    assessment_decision: Literal["supports", "partial", "contradicts", "none"]


class ReportAssessments(BaseModel):
    assessments: list[ReportAnswerAssessment]


def make_client(base_url: str, api_key: str) -> Any:
    import openai

    headers: dict[str, str] = {}
    referer = os.environ.get("OPENROUTER_HTTP_REFERER")
    title = os.environ.get("OPENROUTER_APP_TITLE", "DRAGUN Skill Testbed AutoJudge")
    if "openrouter.ai" in base_url:
        if referer:
            headers["HTTP-Referer"] = referer
        if title:
            headers["X-Title"] = title
    return openai.OpenAI(base_url=base_url, api_key=api_key, default_headers=headers or None)


def call_llm(
    client: Any,
    model: str,
    system_prompt: str,
    user_input: str,
    response_schema: dict,
) -> tuple[str, str]:
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_input},
        ],
        response_format={
            "type": "json_schema",
            "json_schema": {"name": "assessments", "schema": response_schema},
        },
        temperature=0,
        top_p=1,
    )
    message = response.choices[0].message
    reasoning = getattr(message, "reasoning_content", "") or ""
    content = message.content or ""
    if not isinstance(content, str):
        content = json.dumps(content, ensure_ascii=False)
    content = re.sub(r"[\x00-\x1f\x7f]", " ", content)
    return reasoning, content


def load_articles() -> dict[str, dict]:
    articles: dict[str, dict] = {}
    path = DATA_DIR / "trec-2025-dragun-topics.jsonl"
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            data = json.loads(line)
            articles[data["docid"]] = data
    return articles


def load_rubrics() -> dict[str, list]:
    rubrics: dict[str, list] = {}
    for path in sorted((DATA_DIR / "human_rubrics").glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        rubrics[data["topic_id"]] = data["rubrics"]
    if not rubrics:
        raise FileNotFoundError("no rubric JSON files found in data/human_rubrics")
    return rubrics


def load_reports(input_folder: Path) -> pd.DataFrame:
    reports: list[dict[str, str]] = []
    for path_string in sorted(glob.glob(str(input_folder / "*"))):
        path = Path(path_string)
        if path.name.startswith(".") or not path.is_file():
            continue
        run_tag = path.name
        with path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                data = json.loads(line)
                topic_id = data["metadata"]["topic_id"]
                report_text = " ".join(str(item["text"]) for item in data["responses"])
                reports.append(
                    {
                        "topic_id": topic_id,
                        "run_tag": run_tag,
                        "report": report_text,
                        "source_line": str(line_number),
                    }
                )
    if not reports:
        raise FileNotFoundError(f"no report JSONL files found in {input_folder}")
    return pd.DataFrame(reports)


def build_examples(reports: pd.DataFrame, human_assessments: pd.DataFrame) -> dict[tuple[str, str], dict]:
    missing = sorted(set(REPORT_ORGANIZER_RUNS) - set(reports["run_tag"].unique()))
    if missing:
        raise FileNotFoundError(
            "missing organizer report runs needed for few-shot AutoJudge examples: "
            + ", ".join(missing)
        )

    examples: dict[tuple[str, str], dict] = {}
    for topic_id in sorted(human_assessments["topic_id"].unique()):
        for org_run in REPORT_ORGANIZER_RUNS:
            match = reports[(reports["topic_id"] == topic_id) & (reports["run_tag"] == org_run)]
            if match.empty:
                raise ValueError(f"missing organizer example for {topic_id} in {org_run}")
            report_text = match["report"].values[0]
            assessments = human_assessments[
                (human_assessments["topic_id"] == topic_id)
                & (human_assessments["run_tag"] == org_run)
            ].sort_values(by="answer_id", key=lambda x: x.str.extract(r"(\d+)$")[0].astype(int))
            assessments_dict = {row["answer_id"]: row["annotation"] for _, row in assessments.iterrows()}
            examples[(topic_id, org_run)] = {"report": report_text, "assessments": assessments_dict}
    return examples


def run_auto_report_evaluation(
    *,
    input_folder: Path,
    output_folder: Path,
    client: Any,
    model: str,
    run_tags: set[str] | None,
) -> None:
    system_prompt = (SCRIPT_DIR / "system_prompts" / "report_judge.txt").read_text(encoding="utf-8")
    articles = load_articles()
    rubrics = load_rubrics()
    human_assessments = pd.read_csv(DATA_DIR / "human_assessments" / "report_assessments.csv")

    for topic_rubrics in rubrics.values():
        for question in topic_rubrics:
            for answer in question["short_answers"]:
                answer.pop("references", None)

    reports = load_reports(input_folder)
    examples = build_examples(reports, human_assessments)

    participant_reports = reports[~reports["run_tag"].isin(REPORT_ORGANIZER_RUNS)].sort_values(
        ["run_tag", "topic_id"]
    )
    if run_tags:
        participant_reports = participant_reports[participant_reports["run_tag"].isin(run_tags)]
    if participant_reports.empty:
        raise ValueError("no participant reports matched the requested run tags")

    outputs: list[dict[str, str]] = []
    schema = ReportAssessments.model_json_schema()
    for _, row in tqdm(
        participant_reports.iterrows(),
        total=len(participant_reports),
        desc="auto_report_evaluation",
    ):
        topic_id = row["topic_id"]
        run_tag = row["run_tag"]
        report_text = row["report"]

        example_strs = []
        for index, org_run in enumerate(REPORT_ORGANIZER_RUNS, start=1):
            example_strs.append(
                f"Example {index}:\n\n"
                f"{json.dumps(examples[(topic_id, org_run)], ensure_ascii=False, indent=2)}"
            )

        user_input = (
            "Below is the news article:\n\n"
            f"{json.dumps(articles[topic_id], ensure_ascii=False, indent=2)}\n\n"
            "Below is the rubric used to assess reports:\n\n"
            f"{json.dumps(rubrics[topic_id], ensure_ascii=False, indent=2)}\n\n"
            "Below are example reports and their assessments:\n\n"
            f"{chr(10).join(example_strs)}\n\n"
            "Below is the report you need to assess, based on the rubric above and given examples. "
            "Assess whether this report supports, partially supports (partial), contradicts, "
            "or has no relation (none) to each short answer in the rubric.\n\n"
            f"{json.dumps(report_text, ensure_ascii=False, indent=2)}\n\n"
        )
        _reasoning, content = call_llm(client, model, system_prompt, user_input, schema)
        result = ReportAssessments.model_validate_json(content)
        for assessment in result.assessments:
            outputs.append(
                {
                    "topic_id": topic_id,
                    "run_tag": run_tag,
                    "answer_id": assessment.answer_id,
                    "auto_assessment": assessment.assessment_decision,
                    "auto_rationale": assessment.rationale,
                }
            )

    output_folder.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(outputs).to_csv(output_folder / "auto_report_assessments.csv", index=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", default="auto_report_evaluation", choices=["auto_report_evaluation"])
    parser.add_argument("--input_folder_path", required=True, type=Path)
    parser.add_argument("--output_folder_path", required=True, type=Path)
    parser.add_argument("--base-url", default=os.environ.get("JUDGE_BASE_URL", "https://openrouter.ai/api/v1"))
    parser.add_argument("--model", default=os.environ.get("JUDGE_MODEL", "openai/gpt-oss-120b"))
    parser.add_argument("--api-key-env", default=os.environ.get("JUDGE_API_KEY_ENV", "OPENROUTER_API_KEY"))
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--run-tags", nargs="*", help="Evaluate only these non-organizer run tags")
    args = parser.parse_args()

    api_key = args.api_key
    if api_key is None:
        api_key = os.environ.get(args.api_key_env) or os.environ.get("OPENAI_API_KEY") or "EMPTY"
    client = make_client(args.base_url, api_key)
    run_tags = set(args.run_tags) if args.run_tags else None
    run_auto_report_evaluation(
        input_folder=args.input_folder_path,
        output_folder=args.output_folder_path,
        client=client,
        model=args.model,
        run_tags=run_tags,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
