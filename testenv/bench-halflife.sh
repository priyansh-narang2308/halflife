#!/usr/bin/env bash
# Overhead and integrity: what Halflife adds to the request path.
#
# Each comparison starts two fresh gateways from the same binary, in front of
# the same mock provider, at info log level: A on 8090 without Halflife
# (testenv/configs/mock-llm) and B on 8091. hlbench sends the same requests to
# both in alternating pairs and compares latency (p50/p95/p99) and normalized
# response bodies, then both gateways stop. Fresh gateways keep the two sides
# equal: each has served the same traffic and holds the same log store.
#
#   halflife  B has Halflife (testenv/configs/halflife)
#   control   B is a second gateway without Halflife (A/A). Any gap here is
#             noise between two processes on one machine: the floor below
#             which an on/off difference means nothing.
#
# Each runs with one request in flight, then 16. Results:
# testenv/results/{overhead,control}-c<concurrency>.json.
#
# Measures the request path only. Audits run off it, on Halflife's workers; in
# M1 the audit is still a placeholder that does no network I/O.
# Usage: testenv/bench-halflife.sh [pairs]   (default 2000; minimum 1000)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-2000}" WARMUP=200
A=http://127.0.0.1:8090 B=http://127.0.0.1:8091 MOCK=http://127.0.0.1:9101
TMP="$(mktemp -d)"
mock_pid="" gw_pids=()
stop_gateways() { for p in "${gw_pids[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; gw_pids=(); }
cleanup() { stop_gateways; [ -n "$mock_pid" ] && { kill "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true; }; rm -rf "$TMP"; }
trap cleanup EXIT

[ "$N" -ge 1000 ] || { echo "pairs must be at least 1000" >&2; exit 1; }
for u in "$A" "$B"; do
  if curl -sf "$u/health" >/dev/null; then echo "$u is in use (stop the dev stack with: make down)" >&2; exit 1; fi
done
mkdir -p "$ROOT/logs" "$ROOT/bin" "$ROOT/testenv/results"
(cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm && go build -o "$ROOT/bin/hlbench" ./cmd/hlbench)
MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/bench-mockllm.log" 2>&1 &
mock_pid=$!

start_gateway() { # dir, config, port, log
  rm -rf "$TMP/$1"; mkdir -p "$TMP/$1" && cp "$ROOT/testenv/configs/$2/config.json" "$TMP/$1/config.json"
  GATEWAY_LOG_LEVEL=info "$ROOT/scripts/run-gateway.sh" "$TMP/$1" "$3" > "$4" 2>&1 &
  gw_pids+=($!)
}

status=0
# measure name config-for-B concurrency
measure() {
  local name="$1" config="$2" c="$3" log="$ROOT/logs/bench-$1-c$3.log"
  start_gateway a mock-llm 8090 "$ROOT/logs/bench-a-c$c.log"
  start_gateway b "$config" 8091 "$log"
  for _ in $(seq 1 120); do
    curl -sf "$A/health" >/dev/null && curl -sf "$B/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && break
    sleep 0.25
  done
  echo "--- $name, concurrency $c"
  local out=overhead; [ "$name" = control ] && out=control
  "$ROOT/bin/hlbench" -off "$A" -on "$B" -n "$N" -c "$c" -warmup "$WARMUP" -out "$ROOT/testenv/results/$out-c$c.json" || status=1
  stop_gateways # Halflife drains its audit queue on shutdown
  if [ "$name" = halflife ]; then
    # Every request to the Halflife gateway was captured and audited, none dropped.
    local total=$((N + WARMUP))
    local want="\"halflife: stopped (enqueued=$total dropped=0 audited=$total failed=0 abandoned=0 queued=0)\""
    local got; got=$(grep -o '"halflife: stopped ([^)]*)"' "$log" || true)
    echo "  audit queue: $got"
    [ "$got" = "$want" ] || { echo "FAIL  audit totals (want $want)"; status=1; }
  fi
}

for c in 1 16; do
  measure control mock-llm "$c"
  measure halflife halflife "$c"
done
[ "$status" -eq 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
