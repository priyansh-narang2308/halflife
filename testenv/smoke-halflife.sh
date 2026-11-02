#!/usr/bin/env bash
# Smoke test: the gateway with Halflife enabled loads the plugin, runs its hooks
# in the intended order, and returns exactly what it returns without Halflife.
#
# The same requests go to the gateway twice: once with testenv/configs/mock-llm
# (no Halflife) and once with testenv/configs/halflife. Bodies must match byte
# for byte apart from the gateway's own timing fields; headers must match apart
# from per-request IDs, Date and latency.
# Uses only synthetic keys; no real provider is called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GW=http://127.0.0.1:8090
MOCK=http://127.0.0.1:9101
VK=sk-bf-halflife-smoke
TMP="$(mktemp -d)"
mock_pid="" gw_pid=""
stop_gateway() { [ -n "$gw_pid" ] && { kill "$gw_pid" 2>/dev/null || true; wait "$gw_pid" 2>/dev/null || true; }; gw_pid=""; }
cleanup() { stop_gateway; [ -n "$mock_pid" ] && { kill "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

if curl -sf "$GW/health" >/dev/null; then
  echo "port 8090 is in use (stop the dev stack with: make down)" >&2; exit 1
fi
mkdir -p "$ROOT/logs" "$ROOT/bin"
(cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm)
MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/smoke-halflife-mockllm.log" 2>&1 &
mock_pid=$!

start_gateway() { # config-name, log-file
  local app="$TMP/app-$1"
  mkdir -p "$app" && cp "$ROOT/testenv/configs/$1/config.json" "$app/config.json"
  GATEWAY_LOG_LEVEL=debug "$ROOT/scripts/run-gateway.sh" "$app" 8090 > "$2" 2>&1 &
  gw_pid=$!
  for _ in $(seq 1 120); do curl -sf "$GW/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && return; sleep 0.25; done
  echo "gateway ($1) did not start; see $2" >&2; exit 1
}

# Each case writes <dir>/<name>.body (raw), .norm (timing zeroed) and .headers (volatile headers removed).
run_cases() {
  local out="$1"; mkdir -p "$out"
  req() { # name, body, [extra curl args...]
    local name="$1" body="$2"; shift 2
    curl -s -N -D "$out/$name.raw" -o "$out/$name.body" -X POST "$GW/v1/chat/completions" \
      -H 'content-type: application/json' "$@" -d "$body"
    # The gateway writes its own timing into extra_fields (latency, upstream_latency, in ms);
    # it varies between identical requests with or without Halflife, so it is zeroed.
    sed -E 's/"(upstream_)?latency":[0-9.]+/"\1latency":0/g' "$out/$name.body" > "$out/$name.norm"
    tr -d '\r' < "$out/$name.raw" | grep -viE '^(date|x-bifrost-request-id|x-request-id|x-bifrost-trace-id|x-bifrost-upstream-latency-ms|x-bifrost-latency-ms):' > "$out/$name.headers"
  }
  req ok        '{"model":"openai/ok","messages":[{"role":"user","content":"How much does the Acme Cloud Pro plan cost?"}]}' -H "x-bf-vk: $VK"
  req default   '{"model":"openai/ok","messages":[{"role":"user","content":"anything else"}]}' -H "x-bf-vk: $VK"
  req stream    '{"model":"openai/ok","stream":true,"messages":[{"role":"user","content":"Who is the CEO of Acme Cloud?"}]}' -H "x-bf-vk: $VK"
  req fail503   '{"model":"openai/fail-503","messages":[{"role":"user","content":"q"}]}' -H "x-bf-vk: $VK"
  req fallback  '{"model":"openai/fail-500","fallbacks":["openai/ok"],"messages":[{"role":"user","content":"What is the latest version of the Acme SDK?"}]}' -H "x-bf-vk: $VK"
  req novk      '{"model":"openai/ok","messages":[{"role":"user","content":"q"}]}'
}

fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got: $2, want: $3)"; fails=$((fails+1)); fi; }

# 1. Baseline: Halflife absent.
start_gateway mock-llm "$ROOT/logs/smoke-halflife-gateway-off.log"
run_cases "$TMP/off"
stop_gateway

# 2. Halflife enabled.
LOG="$ROOT/logs/smoke-halflife-gateway-on.log"
start_gateway halflife "$LOG"
run_cases "$TMP/on"
stop_gateway

check "startup log: plugin initialized" "$(grep -c '"halflife: initialized (queue_size=256 workers=2 max_claims=5 tavily_relay=tavily)"' "$LOG")" 1
check "startup log: plugin status active" "$(grep -c '"plugin status: halflife - active"' "$LOG")" 1
check "shutdown log: plugin stopped" "$(grep -c '"halflife: stopped"' "$LOG")" 1
check "baseline has no halflife" "$(grep -c 'halflife' "$ROOT/logs/smoke-halflife-gateway-off.log" || true)" 0

# Hook order, from core's debug log (core/bifrost.go): Halflife's pre-hook runs
# first and its post-hook last for every LLM request that reached the plugins.
pre=$(grep -o '"running pre-hook for plugin [^"]*"' "$LOG" | sed 's/.*plugin //; s/"$//' || true)
post=$(grep -o '"running post-hook for plugin [^"]*"' "$LOG" | sed 's/.*plugin //; s/"$//' || true)
# The no-VK request counts too: governance rejects it in its own PreLLMHook,
# which runs after Halflife's, so Halflife's post-hook receives the 401 error.
check "debug log: halflife pre-hook ran on every attempt" "$(echo "$pre" | grep -cx halflife)" 7  # ok, default, stream, 503, fallback x2, novk
check "pre-hooks: halflife always immediately before telemetry (first overall)" \
  "$(echo "$pre" | awk '(prev=="halflife")!=($0=="telemetry"){bad=1} {prev=$0} END{print bad?"no":"yes"}')" yes
check "post-hooks: halflife always immediately after telemetry (last overall)" \
  "$(echo "$post" | awk '(prev=="telemetry")!=($0=="halflife"){bad=1} {prev=$0} END{if(prev!="halflife")bad=1; print bad?"no":"yes"}')" yes
echo "pre-hook order (one attempt):  $(echo "$pre" | awk '$0=="halflife"&&n++{exit} {print}' | tr '\n' ' ')"
echo "post-hook order (one attempt): $(echo "$post" | awk '{print} $0=="halflife"{exit}' | tr '\n' ' ')"

# 3. Responses identical with and without Halflife.
for c in ok default stream fail503 fallback novk; do
  check "body non-empty: $c" "$([ -s "$TMP/on/$c.body" ] && echo yes || echo no)" yes
  check "body identical: $c" "$(cmp -s "$TMP/off/$c.norm" "$TMP/on/$c.norm" && echo same || echo different)" same
  check "headers identical: $c" "$(diff -q "$TMP/off/$c.headers" "$TMP/on/$c.headers" >/dev/null && echo same || echo different)" same
done
check "status codes: ok/503/fallback/novk" \
  "$(for c in ok fail503 fallback novk; do head -1 "$TMP/on/$c.headers" | awk '{printf "%s ", $2}'; done)" "200 503 200 401 "

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
