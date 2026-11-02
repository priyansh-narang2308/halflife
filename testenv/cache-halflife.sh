#!/usr/bin/env bash
# Halflife together with Bifrost's semantic cache, on the real gateway, Redis
# and the mock provider (config testenv/configs/halflife-cache).
#
# Cache linkage: a miss records which report covers the entry it fills;
# direct and semantic hits on that entry return that report
# (X-Halflife-Status: cached) and start no new audit. Tenants stay apart.
# Integrity: the same requests through the cache without Halflife
# (testenv/configs/cache) return identical bodies.
# Uses only synthetic keys; no real provider is called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
VK=sk-bf-halflife-smoke
OTHER_VK=sk-bf-halflife-other # a second tenant (id vk-other)
PRICE="How much does the Acme Cloud Pro plan cost?"
LOG="$ROOT/logs/cache-halflife-gateway.log"

# ask dir name vk question -> dir/name.{status,headers,body,norm}
ask() {
  curl -s -D "$1/$2.headers" -o "$1/$2.body" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-bf-vk: $3" \
    -d "$(jq -cn --arg q "$4" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')" > "$1/$2.status"
  # Timing fields vary between identical requests, with or without Halflife.
  sed -E 's/"(upstream_latency|latency|cache_hit_latency)":[0-9.]+/"\1":0/g' "$1/$2.body" > "$1/$2.norm"
}
hdr()   { tr -d '\r' < "$1/$2.headers" | awk -F': ' -v h="$3" 'tolower($1)==h{print $2}'; }
calls() { curl -s "$MOCK/_mock/requests" | jq -r --arg m "$1" '.by_model[$m] // 0'; }

# The same sequence, once per gateway. Writes are asynchronous, so each miss
# is followed by a short wait before the requests that should hit it.
run_sequence() { # dir
  mkdir -p "$1"
  curl -s -X POST "$MOCK/_mock/reset" >/dev/null
  ask "$1" miss      "$VK"       "$PRICE";                         sleep 0.5
  ask "$1" direct    "$VK"       "$PRICE"
  ask "$1" semantic  "$VK"       "What does Acme Cloud Pro cost?"
  ask "$1" tenant    "$OTHER_VK" "$PRICE";                         sleep 0.5
  ask "$1" tenanthit "$OTHER_VK" "$PRICE"
  ask "$1" unrelated "$VK"       "Who is the CEO of Acme Cloud?"
  curl -s "$MOCK/_mock/requests" | jq -c .by_model > "$1/provider"
}

require_free_ports
ensure_redis
start_mock
NS_OFF="HalflifeCacheOff_$(date +%s)" NS_ON="HalflifeCacheOn_$(date +%s)"

start_gateway cache "$ROOT/logs/cache-halflife-gateway-off.log" "$NS_OFF"
run_sequence "$LIB_TMP/off"
stop_gateway
start_gateway halflife-cache "$LOG" "$NS_ON"
run_sequence "$LIB_TMP/on"
stop_gateway # drains the audit queue
D="$LIB_TMP/on"

echo "--- cache linkage"
r=$(hdr "$D" miss x-halflife-report) id=$(hdr "$D" miss x-bifrost-cache-id)
check "miss: new report, queued" "$(echo "$r" | grep -c '^hlr_')/$(hdr "$D" miss x-halflife-status)" 1/queued
check "miss: report covers the entry it fills (log)" "$(grep -c "\"halflife: report $r covers cache entry $id\"" "$LOG")" 1
for c in direct semantic; do
  check "$c hit: served from the same entry" "$(hdr "$D" $c x-bifrost-cache-hit-type)/$(hdr "$D" $c x-bifrost-cache-id)" "$c/$id"
  check "$c hit: the filling report, status cached" "$(hdr "$D" $c x-halflife-report)/$(hdr "$D" $c x-halflife-status)" "$r/cached"
  check "$c hit: resolved in the log" "$(grep -c "\"halflife: $c cache hit on entry $id, report=$r request=" "$LOG")" 1
done
check "report header exposed on hits" "$(grep -ciE '^access-control-expose-headers:.*x-halflife-status, x-halflife-report' "$D/direct.headers")" 1
r2=$(hdr "$D" tenant x-halflife-report)
check "other tenant, same question: cache miss (identity scope)" "$(hdr "$D" tenant x-bifrost-cache-hit)" false
check "other tenant: its own report" "$([ -n "$r2" ] && [ "$r2" != "$r" ] && echo yes || echo no)/$(hdr "$D" tenant x-halflife-status)" yes/queued
check "other tenant's hit: its own report" "$(hdr "$D" tenanthit x-halflife-report)/$(hdr "$D" tenanthit x-halflife-status)" "$r2/cached"
check "unrelated question: new report" "$(hdr "$D" unrelated x-bifrost-cache-hit)/$(hdr "$D" unrelated x-halflife-status)" false/queued
# Embeddings: one per semantic lookup (miss, semantic, tenant, unrelated); direct hits need none.
check "provider called for the 3 misses only" "$(cat "$D/provider")" '{"mock-embed":4,"ok":3}'
check "three captures" "$(grep -c '"halflife: captured ' "$LOG")" 3
check "three audits, one per answer (not per response)" "$(grep -o '"halflife: stopped ([^)]*)"' "$LOG")" \
  '"halflife: stopped (enqueued=3 dropped=0 audited=3 failed=0 abandoned=0 queued=0)"'

echo "--- integrity (same sequence through the cache without Halflife)"
check "same provider calls" "$(cat "$LIB_TMP/off/provider")" "$(cat "$D/provider")"
for c in miss direct semantic tenant tenanthit unrelated; do
  check "$c: same status and cache outcome" \
    "$(cat "$LIB_TMP/off/$c.status") $(hdr "$LIB_TMP/off" $c x-bifrost-cache-hit) $(hdr "$LIB_TMP/off" $c x-bifrost-cache-hit-type)" \
    "$(cat "$D/$c.status") $(hdr "$D" $c x-bifrost-cache-hit) $(hdr "$D" $c x-bifrost-cache-hit-type)"
  check "$c: body identical" "$(cmp -s "$LIB_TMP/off/$c.norm" "$D/$c.norm" && echo same || echo different)" same
done

finish
