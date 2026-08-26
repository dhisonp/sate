#!/bin/bash
# Operator-run: captures REAL SSE fixtures from Cloudflare AI Gateway so the
# codec is tested against what the gateway actually emits, not what we assume.
#
#   SATE_CF_ACCOUNT=... SATE_CF_TOKEN=... ./scripts/capture-fixtures.sh anthropic/claude-opus-5
#
# The token needs BOTH "Account > Workers AI > Read" (REST) and
# "AI Gateway > Run" (compat/dynamic routes).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SATE_CF_ACCOUNT:?set SATE_CF_ACCOUNT}"
: "${SATE_CF_TOKEN:?set SATE_CF_TOKEN}"
MODEL="${1:-anthropic/claude-opus-5}"
SAFE_NAME=$(echo "$MODEL" | tr '/.' '__')
OUT="Tests/SateCoreTests/Fixtures/live_${SAFE_NAME}.sse"

echo "Capturing $MODEL -> $OUT"
curl -sS -N -D "artifacts/live_${SAFE_NAME}.headers" \
  "https://api.cloudflare.com/client/v4/accounts/${SATE_CF_ACCOUNT}/ai/v1/chat/completions" \
  -H "Authorization: Bearer ${SATE_CF_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "Accept-Encoding: identity" \
  -H "cf-aig-request-timeout: 180000" \
  -d "{\"model\":\"${MODEL}\",\"max_tokens\":64,\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly five words.\"}]}" \
  | tee "$OUT"

echo
echo "--- response headers (cf-aig-log-id is the handle for the dashboard) ---"
grep -iE "cf-aig-|cf-ray|content-type|^HTTP" "artifacts/live_${SAFE_NAME}.headers" || true
