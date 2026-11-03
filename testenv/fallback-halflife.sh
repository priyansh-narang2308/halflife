#!/usr/bin/env bash
# Fallback correctness: however many attempts a request takes, Halflife audits
# the one answer the client receives, exactly once, and audits nothing when no
# attempt succeeds.
#
# Each scenario checks: attempts that reached the mock provider (per model),
# HTTP status, the X-Halflife-Report header, and (after shutdown drains the
# queue) that the reported ID was audited exactly once. The scenarios run
# twice: with max_retries 0 (one try per attempt) and max_retries 2 (the
# provider layer retries each failing attempt). Mock provider only.
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

for u in "$GW" "$MOCK"; do # a leftover mock would silently serve this run
  if curl -s -o /dev/null "$u"; then echo "$u is in use (stop the dev stack with: make down)" >&2; exit 1; fi
done
mkdir -p "$ROOT/logs" "$ROOT/bin"
(cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm)
MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/fallback-mockllm.log" 2>&1 &
mock_pid=$!

fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got: $2, want: $3)"; fails=$((fails+1)); fi; }

start_gateway() { # retries, log
  local app="$TMP/app-$1"
  mkdir -p "$app"
  jq --argjson r "$1" '.providers.openai.network_config.max_retries = $r
    | .providers.openai.network_config.retry_backoff_initial = 1
    | .providers.openai.network_config.retry_backoff_max = 5' \
    "$ROOT/testenv/configs/halflife/config.json" > "$app/config.json"
  GATEWAY_LOG_LEVEL=debug "$ROOT/scripts/run-gateway.sh" "$app" 8090 > "$2" 2>&1 &
  gw_pid=$!
  for _ in $(seq 1 120); do curl -sf "$GW/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && return; sleep 0.25; done
  echo "gateway did not start; see $2" >&2; exit 1
}

# scenario name primary 'fallback,...' -> writes $TMP/<run>/<name>.{status,report,attempts}
scenario() {
  local dir="$1" name="$2" primary="$3" fallbacks="$4"
  local fb; fb=$(jq -cn --arg f "$fallbacks" '$f | split(",") | map(select(. != "")) | map("openai/" + .)')
  curl -s -X POST "$MOCK/_mock/reset" >/dev/null
  curl -s -D "$dir/$name.headers" -o "$dir/$name.body" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-bf-vk: $VK" \
    -d "$(jq -cn --arg m "openai/$primary" --argjson fb "$fb" '{model: $m, fallbacks: $fb, messages: [{role: "user", content: "What is the latest version of the Acme SDK?"}]}')" \
    > "$dir/$name.status"
  tr -d '\r' < "$dir/$name.headers" | awk -F': ' 'tolower($1)=="x-halflife-report"{print $2}' > "$dir/$name.report"
  curl -s "$MOCK/_mock/requests" | jq -c '.by_model' > "$dir/$name.attempts"
}

# expect name status attempts-json audited(0|1) fallback(true|false|-)
expect() {
  local dir="$1" log="$2" name="$3" status="$4" attempts="$5" audited="$6" fallback="$7"
  local id; id=$(cat "$dir/$name.report")
  check "$name: status" "$(cat "$dir/$name.status")" "$status"
  check "$name: provider attempts" "$(jq -cS . "$dir/$name.attempts")" "$(echo "$attempts" | jq -cS .)"
  if [ "$audited" = 1 ]; then
    check "$name: report header" "$(echo "$id" | grep -c '^hlr_')" 1
    check "$name: audited exactly once" "$(grep -c "\"halflife: report $id complete:" "$log")" 1
    check "$name: captured once, fallback=$fallback" "$(grep -c "fallback=$fallback) report=$id " "$log")" 1
    check "$name: answer served by ok" "$(jq -r '.model' "$dir/$name.body")" ok
  else
    check "$name: no report header" "$id" ""
  fi
}

for retries in 0 2; do
  echo "--- max_retries=$retries"
  dir="$TMP/r$retries"; log="$ROOT/logs/fallback-gateway-r$retries.log"
  mkdir -p "$dir"
  start_gateway "$retries" "$log"
  t=$((retries + 1)) # tries per failing attempt
  scenario "$dir" primary-ok          ok        ""
  scenario "$dir" one-fallback        fail-500  ok
  scenario "$dir" two-fallbacks       fail-500  fail-503,ok
  scenario "$dir" rate-limited        fail-429  ok
  scenario "$dir" all-fail            fail-500  fail-503
  scenario "$dir" unused-fallback     ok        fail-500
  stop_gateway # drains the audit queue

  expect "$dir" "$log" primary-ok      200 '{"ok":1}'                                1 false
  expect "$dir" "$log" one-fallback    200 "{\"fail-500\":$t,\"ok\":1}"              1 true
  expect "$dir" "$log" two-fallbacks   200 "{\"fail-500\":$t,\"fail-503\":$t,\"ok\":1}" 1 true
  expect "$dir" "$log" rate-limited    200 "{\"fail-429\":$t,\"ok\":1}"              1 true
  # When every attempt fails, Bifrost returns the primary's error (500), not the last fallback's.
  expect "$dir" "$log" all-fail        500 "{\"fail-500\":$t,\"fail-503\":$t}"       0 -
  expect "$dir" "$log" unused-fallback 200 '{"ok":1}'                                1 false
  check "totals (r=$retries)" "$(grep -o '"halflife: stopped ([^)]*)"' "$log")" \
    '"halflife: stopped (enqueued=5 dropped=0 audited=5 failed=0 abandoned=0 queued=0)"'
  # Retries happen inside the provider layer: plugin hooks run once per
  # attempt (primary or fallback), not once per retry.
  check "pre-hooks per attempt, not per retry (r=$retries)" "$(grep -c '"running pre-hook for plugin halflife"' "$log")" 11
done

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
