#!/usr/bin/env python3
"""Generate a responses-only report directly through OpenRouter as a fallback."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urljoin


def iter_json_objects(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    objects: list[Any] = []
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _end = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        objects.append(value)
    return objects


def normalize_report(candidate: Any) -> dict[str, Any] | None:
    if not isinstance(candidate, dict):
        return None
    responses = candidate.get("responses")
    if not isinstance(responses, list) or not responses:
        return None
    normalized: list[dict[str, Any]] = []
    for response in responses:
        if not isinstance(response, dict):
            return None
        text = response.get("text")
        citations = response.get("citations")
        if not isinstance(text, str) or not text.strip() or not isinstance(citations, list):
            return None
        cleaned_citations = [str(item) for item in citations if isinstance(item, str)]
        normalized.append({"text": text.strip(), "citations": cleaned_citations})
    return {"responses": normalized}


def report_from_text(text: str) -> dict[str, Any] | None:
    for candidate in iter_json_objects(text):
        normalized = normalize_report(candidate)
        if normalized:
            return normalized
    return None


def compact_skill(skill_text: str) -> str:
    # Keep the direct fallback focused and avoid pulling in examples/references.
    front = skill_text.split("## Artifact Workflow", 1)[0]
    citation = ""
    if "## Citation Rules" in skill_text:
        citation = "## Citation Rules" + skill_text.split("## Citation Rules", 1)[1].split("## Evidence Expectations", 1)[0]
    return (front + "\n\n" + citation).strip()


def call_openrouter(
    *,
    base_url: str,
    api_key: str,
    model: str,
    skill_text: str,
    article_text: str,
    reasoning_effort: str,
    service_tier: str,
) -> str:
    headers: dict[str, str] = {}
    referer = os.environ.get("OPENROUTER_HTTP_REFERER")
    title = os.environ.get("OPENROUTER_APP_TITLE", "DRAGUN Skill Testbed Direct Fallback")
    headers["Authorization"] = f"Bearer {api_key}"
    headers["Content-Type"] = "application/json"
    if referer:
        headers["HTTP-Referer"] = referer
    if title:
        headers["X-Title"] = title

    messages = [
        {
            "role": "system",
            "content": (
                "You are running a noninteractive fallback for a news trust report skill. "
                "Return only valid JSON with a top-level responses array. "
                "Do not mention evaluation datasets, benchmarks, hidden IDs, rubrics, or this fallback. "
                "Use only actual http/https URLs in citations; use an empty citation list for limitation sentences."
            ),
        },
        {
            "role": "user",
            "content": (
                "Skill instructions:\n\n"
                f"{compact_skill(skill_text)}\n\n"
                "Article input:\n\n"
                f"{article_text}\n\n"
                "Produce the report JSON now. If you cannot browse, state the limitation in one response sentence "
                "and cite only URLs present in the article input or sources you actually know."
            ),
        },
    ]

    request_payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": 0,
        "top_p": 1,
    }
    if reasoning_effort and reasoning_effort not in {"off", "none"}:
        request_payload["reasoning"] = {"effort": reasoning_effort}
    if service_tier and service_tier not in {"off", "none"}:
        request_payload["service_tier"] = service_tier

    endpoint = urljoin(base_url.rstrip("/") + "/", "chat/completions")

    def send(payload: dict[str, Any]) -> dict[str, Any]:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(endpoint, data=encoded, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=600) as response:
            return json.loads(response.read().decode("utf-8"))

    first_payload = dict(request_payload)
    first_payload["response_format"] = {"type": "json_object"}
    try:
        response = send(first_payload)
    except urllib.error.HTTPError as exc:
        if exc.code not in {400, 404, 422}:
            raise
        response = send(request_payload)

    message = response.get("choices", [{}])[0].get("message", {})
    content = message.get("content") or ""
    if not isinstance(content, str):
        content = json.dumps(content, ensure_ascii=False)
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", content)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("OPENROUTER_CHAT_BASE_URL", "https://openrouter.ai/api/v1"))
    parser.add_argument("--model", required=True)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--skill-file", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--raw-out", type=Path)
    parser.add_argument("--reasoning-effort", default=os.environ.get("CLAUDE_REASONING_EFFORT", "high"))
    parser.add_argument("--service-tier", default=os.environ.get("OPENROUTER_SERVICE_TIER", "flex"))
    parser.add_argument("--api-key-env", default="OPENROUTER_API_KEY")
    args = parser.parse_args()

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        print(f"error: {args.api_key_env} is required", file=sys.stderr)
        return 2

    content = call_openrouter(
        base_url=args.base_url,
        api_key=api_key,
        model=args.model,
        skill_text=args.skill_file.read_text(encoding="utf-8"),
        article_text=args.input.read_text(encoding="utf-8"),
        reasoning_effort=args.reasoning_effort,
        service_tier=args.service_tier,
    )
    if args.raw_out:
        args.raw_out.parent.mkdir(parents=True, exist_ok=True)
        args.raw_out.write_text(content + "\n", encoding="utf-8")

    report = report_from_text(content)
    if not report:
        print("error: direct OpenRouter fallback did not return a valid responses JSON object", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
