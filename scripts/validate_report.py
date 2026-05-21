#!/usr/bin/env python3
"""Validate and optionally wrap a responses-only report into evaluation JSONL."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


WORD_RE = re.compile(r"\b[\w'-]+\b")
PLACEHOLDER_RE = re.compile(r"\[?\s*URL\s*\d+\s*\]?", re.IGNORECASE)
FORBIDDEN_RE = re.compile(
    r"("
    r"human_rubrics|human_assessments|official_evaluation_results|auto_report_assessments|"
    r"auto_judge|autojudge|trec-dragun/resources|trec34/dragun/data|"
    r"rubric|answer key|answer-key|msmarco_v2\.1_doc_"
    r")",
    re.IGNORECASE,
)


@dataclass
class Issue:
    path: str
    severity: str
    message: str


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


def is_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def load_json(path: Path) -> Any:
    raw = path.read_text(encoding="utf-8")
    if raw.lstrip().startswith("```"):
        raise ValueError("input appears to contain a Markdown code fence")
    return json.loads(raw)


def normalize_record(record: Any) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise ValueError("report must be a JSON object")
    if "responses" not in record:
        raise ValueError("report must contain responses")
    return {"responses": record["responses"]}


def validate_responses(
    record: dict[str, Any],
    *,
    require_url_citations: bool,
    topic_id: str | None,
) -> tuple[list[Issue], dict[str, int | float | bool]]:
    issues: list[Issue] = []
    total_words = 0
    total_citations = 0
    url_citation_count = 0
    forbidden_count = 0

    def add(path: str, severity: str, message: str) -> None:
        issues.append(Issue(path, severity, message))

    extra_top = sorted(set(record) - {"responses"})
    if extra_top:
        add("$", "error", f"unexpected top-level key(s): {', '.join(extra_top)}")

    responses = record.get("responses")
    if not isinstance(responses, list) or not responses:
        add("$.responses", "error", "responses must be a non-empty array")
        return issues, {
            "valid": False,
            "word_count": 0,
            "citation_count": 0,
            "url_citation_count": 0,
            "forbidden_source_violations": 0,
            "citation_url_pass_rate": 0.0,
        }

    for index, response in enumerate(responses):
        base = f"$.responses[{index}]"
        if not isinstance(response, dict):
            add(base, "error", "response must be an object")
            continue

        extra_keys = sorted(set(response) - {"text", "citations"})
        if extra_keys:
            add(base, "error", f"unexpected key(s): {', '.join(extra_keys)}")

        text = response.get("text")
        if not isinstance(text, str) or not text.strip():
            add(f"{base}.text", "error", "text must be a non-empty string")
        else:
            if "```" in text:
                add(f"{base}.text", "error", "text must not contain Markdown fences")
            if PLACEHOLDER_RE.search(text):
                add(f"{base}.text", "error", "text must not contain URL placeholders")
            if topic_id and topic_id in text:
                add(f"{base}.text", "error", "text must not mention the hidden topic ID")
                forbidden_count += 1
            if FORBIDDEN_RE.search(text):
                add(f"{base}.text", "error", "text appears to mention forbidden evaluation artifacts")
                forbidden_count += 1
            total_words += word_count(text)

        citations = response.get("citations")
        if not isinstance(citations, list):
            add(f"{base}.citations", "error", "citations must be an array")
            continue
        total_citations += len(citations)
        for citation_index, citation in enumerate(citations):
            citation_path = f"{base}.citations[{citation_index}]"
            if not isinstance(citation, str) or not citation.strip():
                add(citation_path, "error", "citation must be a non-empty string")
                continue
            if PLACEHOLDER_RE.fullmatch(citation.strip()):
                add(citation_path, "error", "citation must not be a placeholder")
            if FORBIDDEN_RE.search(citation):
                add(citation_path, "error", "citation appears to reference forbidden evaluation artifacts")
                forbidden_count += 1
            if is_url(citation):
                url_citation_count += 1
            elif require_url_citations:
                add(citation_path, "error", "citation must be an http or https URL")

    citation_url_pass_rate = 1.0
    if total_citations:
        citation_url_pass_rate = url_citation_count / total_citations

    has_errors = any(issue.severity == "error" for issue in issues)
    stats = {
        "valid": not has_errors,
        "word_count": total_words,
        "citation_count": total_citations,
        "url_citation_count": url_citation_count,
        "forbidden_source_violations": forbidden_count,
        "citation_url_pass_rate": citation_url_pass_rate,
    }
    return issues, stats


def final_record(record: dict[str, Any], run_id: str, topic_id: str) -> dict[str, Any]:
    return {
        "metadata": {
            "run_id": run_id,
            "topic_id": topic_id,
        },
        "responses": record["responses"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--topic-id")
    parser.add_argument("--run-id")
    parser.add_argument("--allow-non-url-citations", action="store_true")
    parser.add_argument("--summary-out", type=Path)
    parser.add_argument("--out-json", type=Path, help="Write a validated evaluator record as JSON")
    parser.add_argument("--out-jsonl", type=Path, help="Append a validated evaluator record as JSONL")
    parser.add_argument("--write-invalid", action="store_true", help="Write wrapped JSON even if invalid")
    args = parser.parse_args()

    try:
        record = normalize_record(load_json(args.report))
    except Exception as exc:  # noqa: BLE001 - CLI error reporting.
        print(f"error: {exc}", file=sys.stderr)
        return 2

    issues, stats = validate_responses(
        record,
        require_url_citations=not args.allow_non_url_citations,
        topic_id=args.topic_id,
    )

    summary = {
        **stats,
        "topic_id": args.topic_id,
        "run_id": args.run_id,
        "issues": [asdict(issue) for issue in issues],
    }

    if args.summary_out:
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        args.summary_out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    else:
        print(json.dumps(summary, ensure_ascii=False, indent=2))

    should_write = bool(stats["valid"]) or args.write_invalid
    if should_write and (args.out_json or args.out_jsonl):
        if not args.topic_id or not args.run_id:
            print("error: --topic-id and --run-id are required when writing DRAGUN output", file=sys.stderr)
            return 2
        wrapped = final_record(record, args.run_id, args.topic_id)
        if args.out_json:
            args.out_json.parent.mkdir(parents=True, exist_ok=True)
            args.out_json.write_text(json.dumps(wrapped, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if args.out_jsonl:
            args.out_jsonl.parent.mkdir(parents=True, exist_ok=True)
            with args.out_jsonl.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(wrapped, ensure_ascii=False) + "\n")

    return 0 if stats["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
