#!/usr/bin/env bash
# Smoke test: the real Bifrost gateway talking to the mock LLM provider.
# Uses only the synthetic key "sk-halflife-mock"; no real provider is called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/data/smoke-mock-llm"
GW=http://127.0.0.1:8090
MOCK=http://127.0.0.1:9101
TMP="$(mktemp -d)"
pids=()
cleanup() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

for u in "$GW" "$MOCK"; do # a leftover mock would silently serve this run
  if curl -s -o /dev/null "$u"; then echo "$u is in use (stop the dev stack with: make down)" >&2; exit 1; fi
done

rm -rf "$APP_DIR" && mkdir -p "$APP_DIR" "$ROOT/logs"
cp "$ROOT/testenv/configs/mock-llm/config.json" "$APP_DIR/config.json"

(cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm)
MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/smoke-mockllm.log" 2>&1 & pids+=($!)
"$ROOT/scripts/run-gateway.sh" "$APP_DIR" 8090 > "$ROOT/logs/smoke-gateway.log" 2>&1 & pids+=($!)

for _ in $(seq 1 120); do
  curl -sf "$GW/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && break
  sleep 0.25
done
curl -sf "$GW/health" >/dev/null || { echo "gateway did not start"; exit 1; }
curl -s -X POST "$MOCK/_mock/reset" >/dev/null

fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got: $2, want: $3)"; fails=$((fails+1)); fi; }
VK=sk-bf-halflife-smoke   # virtual key declared in testenv/configs/mock-llm/config.json
chat() { curl -s -o "$1" -w '%{http_code}' -X POST "$GW/v1/chat/completions" -H 'content-type: application/json' -H "x-bf-vk: $VK" -d "$2"; }

# 0. Without a virtual key the gateway refuses (enforce_auth_on_inference defaults to true).
curl -s -X POST "$MOCK/_mock/reset" >/dev/null
code=$(curl -s -o $TMP/hl-0.json -w '%{http_code}' -X POST "$GW/v1/chat/completions" -H 'content-type: application/json' -d '{"model":"openai/ok","messages":[{"role":"user","content":"q"}]}')
check "no virtual key: refused" "$code" 401
check "no virtual key: never reached provider" "$(curl -s "$MOCK/_mock/requests" | jq -r '.total')" 0

# 1. Scripted reply comes back through the gateway unchanged.
code=$(chat $TMP/hl-1.json '{"model":"openai/ok","messages":[{"role":"user","content":"How much does the Acme Cloud Pro plan cost?"}]}')
check "scripted reply: status" "$code" 200
check "scripted reply: content" "$(jq -r '.choices[0].message.content' $TMP/hl-1.json)" 'The Acme Cloud Pro plan costs $20 per month and includes 100 GB of storage.'
check "scripted reply: usage passed through" "$(jq -r '.usage.completion_tokens' $TMP/hl-1.json)" 15

# 2. Injected provider failure surfaces as an error.
code=$(chat $TMP/hl-2.json '{"model":"openai/fail-503","messages":[{"role":"user","content":"q"}]}')
check "injected 503: status" "$code" 503

# 3. Streaming passes through as SSE ending in [DONE].
curl -s -N -X POST "$GW/v1/chat/completions" -H 'content-type: application/json' -H "x-bf-vk: $VK" \
  -d '{"model":"openai/ok","stream":true,"messages":[{"role":"user","content":"Who is the CEO of Acme Cloud?"}]}' > $TMP/hl-3.sse
text=$( (grep '^data: {' $TMP/hl-3.sse || true) | sed 's/^data: //' | jq -rj '.choices[0].delta.content // empty')
check "streaming: reassembled text" "$text" "Acme Cloud's CEO is Jordan Lee, who founded the company in 2015."
check "streaming: terminated" "$(grep -c '^data: \[DONE\]' $TMP/hl-3.sse || true)" 1

# 4. Fallback: primary fails, fallback succeeds; both attempts reach the provider.
curl -s -X POST "$MOCK/_mock/reset" >/dev/null
code=$(chat $TMP/hl-4.json '{"model":"openai/fail-500","fallbacks":["openai/ok"],"messages":[{"role":"user","content":"What is the latest version of the Acme SDK?"}]}')
check "fallback: status" "$code" 200
check "fallback: served by fallback model" "$(jq -r '.model' $TMP/hl-4.json)" ok
counts=$(curl -s "$MOCK/_mock/requests")
check "fallback: primary attempted once" "$(echo "$counts" | jq -r '.by_model["fail-500"] // 0')" 1
check "fallback: fallback attempted once" "$(echo "$counts" | jq -r '.by_model["ok"] // 0')" 1

echo "mock request counts after fallback test: $counts"
echo "fallback response extra_fields: $(jq -c '.extra_fields // {} | {provider, model_requested: .original_model_requested, resolved: .resolved_model_used}' $TMP/hl-4.json)"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
