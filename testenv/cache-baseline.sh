#!/usr/bin/env bash
# Semantic cache baseline: Bifrost's built-in semantic_cache plugin, unmodified
# and without Halflife, on Redis 8.2.2 (search module) with the mock
# provider's deterministic embeddings (testenv/mockllm/embeddings.go).
#
# Walks one cache entry through its life and checks each step three ways:
# what the client sees (x-bifrost-cache-* headers), what reached the provider
# (mock request counts), and what Bifrost wrote (the Redis entry, and the
# cache_debug column of the gateway's own request log).
#
#   1 miss            provider answers, embedding computed, entry written
#   2 direct hit      same request: served from cache, no provider, no embedding
#   3 semantic hit    paraphrase: served from cache, embedding only
#   4 unrelated miss  different question on the same topic
#   5 identity scope  same question from another virtual key: miss
#
# Each run uses a fresh namespace, removed afterwards. Starts the Redis
# container if it is not running (and stops it again); leaves it alone if it is.
# Uses only synthetic keys; no real provider is called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GW=http://127.0.0.1:8090
MOCK=http://127.0.0.1:9101
VK=sk-bf-halflife-smoke
OTHER_VK=sk-bf-halflife-other # a second tenant (id vk-other)
REDIS=halflife-redis
NS="HalflifeCacheBaseline_$(date +%s)"
TMP="$(mktemp -d)"
APP="$TMP/app"
LOG="$ROOT/logs/cache-baseline-gateway.log"
mock_pid="" gw_pid="" started_redis=""
stop_gateway() { [ -n "$gw_pid" ] && { kill "$gw_pid" 2>/dev/null || true; wait "$gw_pid" 2>/dev/null || true; }; gw_pid=""; }
rcli() { docker exec "$REDIS" redis-cli "$@"; }
cleanup() {
  stop_gateway
  [ -n "$mock_pid" ] && { kill "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true; }
  if [ -n "$started_redis" ]; then
    docker stop "$REDIS" >/dev/null 2>&1 || true
  else
    rcli FT.DROPINDEX "$NS" DD >/dev/null 2>&1 || true # the index and its entries
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

for u in "$GW" "$MOCK"; do # a leftover mock would silently serve this run
  if curl -s -o /dev/null "$u"; then echo "$u is in use (stop the dev stack with: make down)" >&2; exit 1; fi
done
docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)" >&2; exit 1; }
if ! docker ps --format '{{.Names}}' | grep -qx "$REDIS"; then
  docker run -d --rm --name "$REDIS" -p 127.0.0.1:6380:6379 redis:8.2.2 redis-server --save '' --appendonly no >/dev/null
  started_redis=1
  for _ in $(seq 1 40); do rcli PING 2>/dev/null | grep -q PONG && break; sleep 0.25; done
fi

mkdir -p "$ROOT/logs" "$ROOT/bin" "$APP"
(cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm)
MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/cache-baseline-mockllm.log" 2>&1 &
mock_pid=$!
jq --arg ns "$NS" '.plugins[0].config.vector_store_namespace = $ns' "$ROOT/testenv/configs/cache/config.json" > "$APP/config.json"
GATEWAY_LOG_LEVEL=debug "$ROOT/scripts/run-gateway.sh" "$APP" 8090 > "$LOG" 2>&1 &
gw_pid=$!
for _ in $(seq 1 120); do curl -sf "$GW/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && break; sleep 0.25; done

fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got: $2, want: $3)"; fails=$((fails+1)); fi; }

# ask name vk question -> $TMP/<name>.{status,headers,body}
ask() {
  curl -s -D "$TMP/$1.headers" -o "$TMP/$1.body" -w '%{http_code}' -X POST "$GW/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-bf-vk: $2" \
    -d "$(jq -cn --arg q "$3" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')" > "$TMP/$1.status"
}
hdr()     { tr -d '\r' < "$TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
answer()  { jq -r '.choices[0].message.content' "$TMP/$1.body"; }
calls()   { curl -s "$MOCK/_mock/requests" | jq -r --arg m "$1" '.by_model[$m] // 0'; }
entries() { rcli --scan --pattern "$NS:*" | grep -c . || true; }

check "plugin active" "$(grep -c '"plugin status: semantic_cache - active"' "$LOG")" 1
check "namespace index created in Redis" "$(rcli FT._LIST | grep -cx "$NS")" 1

echo "--- 1 miss"
ask miss "$VK" "How much does the Acme Cloud Pro plan cost?"
id=$(hdr miss x-bifrost-cache-id)
check "status" "$(cat "$TMP/miss.status")" 200
check "cache hit" "$(hdr miss x-bifrost-cache-hit)" false
check "provider answered" "$(calls ok)" 1
check "embedding computed with mock-embed" "$(calls mock-embed)/$(hdr miss x-bifrost-cache-model-used)" 1/mock-embed
check "answer is the scripted one" "$(answer miss)" "The Acme Cloud Pro plan costs \$20 per month and includes 100 GB of storage."
# The write is asynchronous (a goroutine after the response).
for _ in $(seq 1 20); do [ "$(rcli EXISTS "$NS:$id")" = 1 ] && break; sleep 0.1; done
check "entry written to Redis under the cache id" "$(rcli EXISTS "$NS:$id")" 1
check "entry holds the response and its embedding" \
  "$(rcli HGETALL "$NS:$id" | awk 'NR%2==1' | grep -cxE 'response|embedding|expires_at|cache_key')" 4
# Bifrost stores the cache key hex-encoded in the hash.
check "entry's cache key (hex-encoded)" "$(rcli HGET "$NS:$id" cache_key | xxd -r -p)" halflife-smoke
expires=$(rcli HGET "$NS:$id" expires_at)
check "entry expires ~5 min from now (TTL 5m)" "$(( expires - $(date +%s) > 280 && expires - $(date +%s) <= 300 ))" 1

echo "--- 2 direct hit"
ask direct "$VK" "How much does the Acme Cloud Pro plan cost?"
check "status" "$(cat "$TMP/direct.status")" 200
check "cache hit, direct" "$(hdr direct x-bifrost-cache-hit)/$(hdr direct x-bifrost-cache-hit-type)" true/direct
check "same entry" "$(hdr direct x-bifrost-cache-id)" "$id"
check "provider not called" "$(calls ok)" 1
check "no embedding needed" "$(calls mock-embed)" 1
check "same answer" "$(answer direct)" "$(answer miss)"
check "same response id" "$(jq -r .id "$TMP/direct.body")" "$(jq -r .id "$TMP/miss.body")"

echo "--- 3 semantic hit"
ask semantic "$VK" "What does Acme Cloud Pro cost?"
check "status" "$(cat "$TMP/semantic.status")" 200
check "cache hit, semantic" "$(hdr semantic x-bifrost-cache-hit)/$(hdr semantic x-bifrost-cache-hit-type)" true/semantic
check "same entry" "$(hdr semantic x-bifrost-cache-id)" "$id"
check "similarity at or above threshold 0.8" \
  "$(awk -v s="$(hdr semantic x-bifrost-cache-similarity)" -v t="$(hdr semantic x-bifrost-cache-threshold)" 'BEGIN{print (t==0.8 && s>=t && s<1) ? "yes" : "no"}')" yes
check "provider not called" "$(calls ok)" 1
check "one embedding for the lookup" "$(calls mock-embed)" 2
check "the cached answer served to a different wording" "$(answer semantic)" "$(answer miss)"

echo "--- 4 unrelated miss"
ask unrelated "$VK" "Who is the CEO of Acme Cloud?"
check "cache miss" "$(hdr unrelated x-bifrost-cache-hit)" false
check "new entry" "$([ "$(hdr unrelated x-bifrost-cache-id)" != "$id" ] && echo yes || echo no)" yes
check "provider called" "$(calls ok)" 2
check "its own answer" "$(answer unrelated)" "Acme Cloud's CEO is Jordan Lee, who founded the company in 2015."

echo "--- 5 identity scope"
ask tenant "$OTHER_VK" "How much does the Acme Cloud Pro plan cost?"
check "same question, other virtual key: miss" "$(hdr tenant x-bifrost-cache-hit)" false
check "provider called" "$(calls ok)" 3
sleep 0.5
check "entries in Redis" "$(entries)" 3

# Bifrost's request log (logs.db, written asynchronously; complete after
# shutdown) records cache_debug for every request, with its virtual key.
stop_gateway
rows=$(sqlite3 -separator ' ' "$APP/logs.db" \
  "select virtual_key_id, json_extract(cache_debug,'\$.cache_hit'), coalesce(json_extract(cache_debug,'\$.hit_type'),'-') from logs where object_type='chat_completion' order by timestamp")
echo "request log:"; echo "$rows" | sed 's/^/  /'
check "request log: one row per request, cache outcome recorded" "$(echo "$rows" | tr '\n' ';')" \
  "vk-smoke 0 -;vk-smoke 1 direct;vk-smoke 1 semantic;vk-smoke 0 -;vk-other 0 -;"
check "request log: semantic similarity recorded" \
  "$(sqlite3 "$APP/logs.db" "select json_extract(cache_debug,'\$.similarity') >= 0.8 from logs where json_extract(cache_debug,'\$.hit_type')='semantic'")" 1

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
