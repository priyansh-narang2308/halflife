#!/usr/bin/env bash
# Halflife together with Bifrost's semantic cache, on the real gateway, Redis
# and the mock provider (config testenv/configs/halflife-cache).
#
# Cache linkage: a miss records which report covers the entry it fills;
# direct and semantic hits on that entry return that report
# (X-Halflife-Status: cached) and start no new audit. Tenants stay apart.
# TTL cap: Halflife's cache_ttl_seconds (60) replaces the cache's 5m TTL on
# every entry it writes, and caps a longer x-bf-cache-ttl; a shorter one stays.
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

# ask dir name vk question [extra header] -> dir/name.{status,headers,body,norm}
ask() {
  curl -s -D "$1/$2.headers" -o "$1/$2.body" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-bf-vk: $3" ${5:+-H "$5"} \
    -d "$(jq -cn --arg q "$4" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')" > "$1/$2.status"
  # Timing fields vary between identical requests, with or without Halflife.
  sed -E 's/"(upstream_latency|latency|cache_hit_latency)":[0-9.]+/"\1":0/g' "$1/$2.body" > "$1/$2.norm"
}
hdr()   { tr -d '\r' < "$1/$2.headers" | awk -F': ' -v h="$3" 'tolower($1)==h{print $2}'; }
# expiry dir name ns -> seconds until the request's cache entry expires, and
# its Redis key TTL (-1: the cache expires entries by field, not by Redis).
expiry() {
  local key="$3:$(hdr "$1" "$2" x-bifrost-cache-id)"
  for _ in $(seq 1 20); do [ "$(rcli EXISTS "$key")" = 1 ] && break; sleep 0.1; done
  echo "$(( $(rcli HGET "$key" expires_at) - $(date +%s) )) $(rcli TTL "$key")"
}
near() { awk -v g="${1% *}" -v w="$2" 'BEGIN{print (g <= w && g >= w-3) ? "~" w : g}'; }
calls() { curl -s "$MOCK/_mock/requests" | jq -r --arg m "$1" '.by_model[$m] // 0'; }

# The same sequence, once per gateway. Writes are asynchronous, so each miss
# is followed by a short wait before the requests that should hit it.
run_sequence() { # dir ns
  mkdir -p "$1"
  curl -s -X POST "$MOCK/_mock/reset" >/dev/null
  ask "$1" miss      "$VK"       "$PRICE";                         sleep 0.5
  expiry "$1" miss "$2" > "$1/miss.expiry"
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
run_sequence "$LIB_TMP/off" "$NS_OFF"
stop_gateway
start_gateway halflife-cache "$LOG" "$NS_ON"
run_sequence "$LIB_TMP/on" "$NS_ON"
D="$LIB_TMP/on"
# Client TTLs, on questions sharing no content words with the others, so each
# misses and writes its own entry.
ask "$D" shortttl "$VK" "Which regions host the storage servers?"      "x-bf-cache-ttl: 20"
ask "$D" longttl  "$VK" "Are student discounts offered on invoices?"   "x-bf-cache-ttl: 1h"
for c in shortttl longttl; do expiry "$D" $c "$NS_ON" > "$D/$c.expiry"; done
stop_gateway # drains the audit queue

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
# Plus the two client-TTL questions asked after the sequence.
check "five captures" "$(grep -c '"halflife: captured ' "$LOG")" 5
check "five audits, one per answer (not per response)" "$(grep -o '"halflife: stopped ([^)]*)"' "$LOG")" \
  '"halflife: stopped (enqueued=5 dropped=0 audited=5 failed=0 abandoned=0 queued=0)"'

echo "--- TTL cap"
check "without Halflife: the cache's TTL (5m)" "$(near "$(cat "$LIB_TMP/off/miss.expiry")" 300)" "~300"
check "with Halflife: capped to cache_ttl_seconds (60)" "$(near "$(cat "$D/miss.expiry")" 60)" "~60"
check "client-TTL questions: misses with their own entries" \
  "$(hdr "$D" shortttl x-bifrost-cache-hit)/$(hdr "$D" longttl x-bifrost-cache-hit)/$(printf '%s\n' "$id" "$(hdr "$D" unrelated x-bifrost-cache-id)" "$(hdr "$D" shortttl x-bifrost-cache-id)" "$(hdr "$D" longttl x-bifrost-cache-id)" | sort -u | grep -c .)" false/false/4
check "client x-bf-cache-ttl 1h: capped to 60" "$(near "$(cat "$D/longttl.expiry")" 60)" "~60"
check "client x-bf-cache-ttl 20s: shorter, kept" "$(near "$(cat "$D/shortttl.expiry")" 20)" "~20"
check "Redis key TTL is -1 (expiry is the expires_at field)" \
  "$(cut -d' ' -f2 "$LIB_TMP/off/miss.expiry" "$D/miss.expiry" "$D/longttl.expiry" | sort -u)" -1
check "cap logged at start" "$(grep -c 'cache_ttl=1m0s report_store=memory)"' "$LOG")" 1

echo "--- integrity (same sequence through the cache without Halflife)"
check "same provider calls" "$(cat "$LIB_TMP/off/provider")" "$(cat "$D/provider")"
for c in miss direct semantic tenant tenanthit unrelated; do
  check "$c: same status and cache outcome" \
    "$(cat "$LIB_TMP/off/$c.status") $(hdr "$LIB_TMP/off" $c x-bifrost-cache-hit) $(hdr "$LIB_TMP/off" $c x-bifrost-cache-hit-type)" \
    "$(cat "$D/$c.status") $(hdr "$D" $c x-bifrost-cache-hit) $(hdr "$D" $c x-bifrost-cache-hit-type)"
  check "$c: body identical" "$(cmp -s "$LIB_TMP/off/$c.norm" "$D/$c.norm" && echo same || echo different)" same
done

finish
