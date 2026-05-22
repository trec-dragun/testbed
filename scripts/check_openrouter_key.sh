#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/tmp/openrouter"
mkdir -p "$LOG_DIR"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "error: OPENROUTER_API_KEY is required for --provider openrouter" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "OpenRouter key preflight skipped: curl not found" >&2
  exit 0
fi

STATUS_FILE="$(mktemp "$LOG_DIR/key_status.XXXXXX")"
BODY_FILE="$(mktemp "$LOG_DIR/key_body.XXXXXX")"

HTTP_STATUS="$(
  curl -sS \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -o "$BODY_FILE" \
    -w "%{http_code}" \
    https://openrouter.ai/api/v1/key \
    2>"$STATUS_FILE" || true
)"

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "error: OpenRouter rejected OPENROUTER_API_KEY during preflight (HTTP $HTTP_STATUS)" >&2
  echo "OpenRouter response:" >&2
  sed -n '1,20p' "$BODY_FILE" >&2 || true
  if [[ -s "$STATUS_FILE" ]]; then
    echo "curl diagnostics:" >&2
    sed -n '1,20p' "$STATUS_FILE" >&2 || true
  fi
  echo "Create or regenerate an OpenRouter API key and export it as OPENROUTER_API_KEY." >&2
  exit 2
fi

echo "OpenRouter key preflight... ok"
