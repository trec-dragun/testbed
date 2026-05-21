#!/usr/bin/env python3
"""Score DRAGUN report-generation assessments."""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

import pandas as pd


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"
RUBRICS_DIR = DATA_DIR / "human_rubrics"
IMPORTANCE_MAP = {"A: Have to Know": 4, "B: Good to Know": 2, "C: Nice to Know": 1}


def load_rubrics() -> pd.DataFrame:
    rows = []
    for path_string in sorted(glob.glob(str(RUBRICS_DIR / "*.json"))):
        with open(path_string, encoding="utf-8") as handle:
            data = json.load(handle)
        topic_id = data["topic_id"]
        for question in data["rubrics"]:
            for answer in question["short_answers"]:
                rows.append(
                    {
                        "topic_id": topic_id,
                        "rubric_question_rank": int(question["question_id"].split("-")[-1]),
                        "answer_id": answer["answer_id"],
                        "question_importance": question["importance"],
                    }
                )
    if not rows:
        raise FileNotFoundError(f"no rubric JSON files found in {RUBRICS_DIR}")
    df = pd.DataFrame(rows)
    df["question_score"] = df["question_importance"].map(IMPORTANCE_MAP)
    return df


def score_report_generation(
    assessments: pd.DataFrame,
    rubric_answers: pd.DataFrame,
    output_dir: Path,
    prefix: str,
) -> None:
    assessments["score"] = assessments["annotation"].map(
        {"supports": 1, "partial": 0.5, "contradicts": -1, "none": 0}
    )
    assessments = assessments.merge(rubric_answers, on=["topic_id", "answer_id"], how="left")

    if assessments.isna().any().any():
        missing = assessments[assessments.isna().any(axis=1)].head(5)
        raise ValueError(f"missing values detected in assessments:\n{missing}")

    results = []
    for topic_id in sorted(assessments["topic_id"].unique()):
        rubric_topic = rubric_answers[rubric_answers["topic_id"] == topic_id]
        max_score = rubric_topic.drop_duplicates(subset=["rubric_question_rank"])["question_score"].sum()
        topic_runs = sorted(assessments[assessments["topic_id"] == topic_id]["run_tag"].unique())
        for run_tag in topic_runs:
            part = assessments[(assessments["topic_id"] == topic_id) & (assessments["run_tag"] == run_tag)]
            supportive_total = 0.0
            contradictory_total = 0.0
            for qid in sorted(part["rubric_question_rank"].unique()):
                q_part = part[part["rubric_question_rank"] == qid]
                weight = q_part["question_score"].iloc[0]
                answer_count = len(q_part)
                supportive_total += q_part[q_part["score"] > 0]["score"].sum() / answer_count * weight
                contradictory_total += -q_part[q_part["score"] < 0]["score"].sum() / answer_count * weight
            results.append(
                {
                    "run_tag": run_tag,
                    "topic_id": topic_id,
                    "supportive_score": supportive_total / max_score,
                    "contradictory_score": contradictory_total / max_score,
                }
            )

    output_dir.mkdir(parents=True, exist_ok=True)
    per_topic = pd.DataFrame(results)
    per_run = (
        per_topic.groupby("run_tag", as_index=False)
        .agg(
            supportive_score=("supportive_score", "mean"),
            contradictory_score=("contradictory_score", "mean"),
        )
        .sort_values("supportive_score", ascending=False)
    )
    per_topic.to_csv(output_dir / f"{prefix}_report_generation_per_topic_results.csv", index=False)
    per_run.to_csv(output_dir / f"{prefix}_report_generation_per_run_results.csv", index=False)
    print(per_run.to_string(index=False))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", required=True, choices=["report_generation_evaluation"])
    parser.add_argument("--type", required=True, choices=["human", "auto"])
    parser.add_argument("--assessment_input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)
    rubric_answers = load_rubrics()
    assessments = pd.read_csv(args.assessment_input)
    if args.type == "auto":
        assessments = assessments.rename(columns={"auto_assessment": "annotation"})
    score_report_generation(assessments, rubric_answers, args.output, args.type)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
