#!/usr/bin/env bash
# Live Tavily validation through Bifrost's relay (config testenv/configs/relay-live).
# SPENDS REAL TAVILY CREDITS: at most MAX_SEARCHES searches (about 12 credits)
# plus one single-URL Extract. GET /usage (free) is read before and after.
#
# Records, per call: HTTP status, usage.credits, Tavily's response_time, the
# gateway's own latency, result count and error message, to
# testenv/results/tavily-live.json. The API key is read by the gateway from
# .env (env.TAVILY_API_KEY); the script never reads it, and checks that the
# record and the gateway log hold no Tavily-key-shaped string.
#
# DRY_RUN=1 sends the same calls to mock Tavily instead (no credits), to check
# the script itself; its record goes to tavily-live-dryrun.json.
# USAGE_ONLY=1 makes one free GET /usage and adds it to the existing record as
# usage.later: Tavily's counters lag the calls, so the run's own after-read
# can still show the old totals.
set -Eeuo pipefail
trap 'echo "live-tavily.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
VERIFIER=sk-bf-halflife-verifier
MAX_SEARCHES=10
OUT="$ROOT/testenv/results/tavily-live.json"
DRY_RUN="${DRY_RUN:-}"
LOG="$ROOT/logs/live-tavily-gateway.log"
QUERY="What is the latest stable version of the Go programming language?"

# Only the gateway reads the key; this script never holds it.
grep -q '^TAVILY_API_KEY=.' "$ROOT/.env" 2>/dev/null || { echo "TAVILY_API_KEY is not set in .env" >&2; exit 1; }
CONFIG=relay-live
if [ -n "$DRY_RUN" ]; then
  OUT="$ROOT/testenv/results/tavily-live-dryrun.json" CONFIG="$LIB_TMP/dryrun.json"
  jq '.relays |= map(.base_url = "http://127.0.0.1:9102" | if .name == "tavily" then .credential.value = "tvly-mock" else . end)' \
    "$ROOT/testenv/configs/relay-live/config.json" > "$CONFIG"
fi

searches=0
# call label relay method path body [header...] -> one JSON line in $LIB_TMP/calls.jsonl
call() {
  local label=$1 relay=$2 method=$3 path=$4 body=$5; shift 5
  if [ "$path" = /search ]; then
    searches=$((searches + 1))
    [ "$searches" -le "$MAX_SEARCHES" ] || { echo "search cap ($MAX_SEARCHES) reached" >&2; exit 1; }
  fi
  local args=(-s -m 60 -D "$LIB_TMP/$label.headers" -o "$LIB_TMP/$label.body" -w '%{http_code} %{time_total}\n' -X "$method"
    "$GW/relay/$relay$path" -H "x-bf-vk: $VERIFIER")
  [ -n "$body" ] && args+=(-H 'content-type: application/json' -d "$body")
  for h in "$@"; do args+=(-H "$h"); done
  read -r status total < <(curl "${args[@]}")
  local gwid; gwid=$(tr -d '\r' < "$LIB_TMP/$label.headers" | awk -F': ' 'tolower($1)=="x-bifrost-request-id"{print $2}')
  jq -c --arg label "$label" --arg path "$path" --argjson status "$status" --argjson total "$total" --arg gwid "$gwid" \
    --argjson req "${body:-null}" '{
      label: $label, path: $path, request: ($req // null), status: $status, client_seconds: $total, gateway_request_id: $gwid,
      credits: (.usage.credits // null), tavily_response_time: (.response_time // null), tavily_request_id: (.request_id // null),
      results: ((.results // null) | if . == null then null else length end),
      failed_results: ((.failed_results // null) | if . == null then null else length end),
      published_dates: ([(.results // [])[] | select(.published_date != null)] | length),
      top_domains: ([(.results // [])[:3][] | .url | capture("^https?://(?<h>[^/]+)").h]),
      error: (if $status >= 400 then (.detail.error // .detail // .error.message // .) else null end)
    }' "$LIB_TMP/$label.body" 2>/dev/null >> "$LIB_TMP/calls.jsonl" \
    || jq -cn --arg label "$label" --argjson status "$status" --arg raw "$(head -c 300 "$LIB_TMP/$label.body")" \
         '{label: $label, status: $status, error: $raw}' >> "$LIB_TMP/calls.jsonl"
  printf '%-16s %s  credits=%s  %ss\n' "$label" "$status" "$(jq -r '.usage.credits // "-"' "$LIB_TMP/$label.body" 2>/dev/null || echo -)" "$total"
}

require_free_ports
start_mock
[ -n "$DRY_RUN" ] && start_mock_tavily
start_gateway "$CONFIG" "$LOG"

if [ -n "${USAGE_ONLY:-}" ]; then
  [ -f "$OUT" ] || { echo "no record at $OUT" >&2; exit 1; }
  curl -s -m 30 "$GW/relay/tavily/usage" -H "x-bf-vk: $VERIFIER" \
    | jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{read_at: $at, key_usage: .key.usage, search_usage: .key.search_usage, extract_usage: .key.extract_usage, plan_usage: .account.plan_usage, plan_limit: .account.plan_limit, paygo_usage: .account.paygo_usage}' > "$LIB_TMP/later.json"
  cat "$LIB_TMP/later.json"
  jq --slurpfile l "$LIB_TMP/later.json" '.usage.later = $l[0]' "$OUT" > "$LIB_TMP/out.json" && mv "$LIB_TMP/out.json" "$OUT"
  exit 0
fi
: > "$LIB_TMP/calls.jsonl"

basic() { jq -cn --arg q "$1" '{query: $q, search_depth: "basic", max_results: 3, include_usage: true}'; }
call usage-before tavily GET /usage ""
call basic        tavily POST /search "$(basic "$QUERY")" 'X-Project-ID: vk-smoke' 'X-Session-Id: hlr_live_basic'
call repeat       tavily POST /search "$(basic "$QUERY")" 'X-Project-ID: vk-smoke' 'X-Session-Id: hlr_live_repeat'
call advanced     tavily POST /search "$(basic "$QUERY" | jq -c '.search_depth = "advanced"')"
call max-age-24h  tavily POST /search "$(basic "$QUERY" | jq -c '.max_age_hours = 24')"
call news-week    tavily POST /search "$(basic "Go programming language release" | jq -c '.topic = "news" | .time_range = "week"')"
call no-usage     tavily POST /search "$(basic "$QUERY" | jq -c 'del(.include_usage)')"
call invalid      tavily POST /search "$(basic "$QUERY" | jq -c '.max_results = 50')"
call bad-key      tavily-badkey POST /search "$(basic "$QUERY")"
call extract-1url tavily POST /extract '{"urls":["https://go.dev/doc/devel/release"],"extract_depth":"basic","include_usage":true}'
sleep 2 # let Tavily's usage counter catch up
call usage-after  tavily GET /usage ""
stop_gateway # flushes the relay log

relay_rows=$(sqlite3 -json "$GATEWAY_APP/logs.db" \
  "select request_id, path, status_code, units, cost, latency, upstream_latency, overhead_latency from relay_logs order by timestamp" || echo '[]')
mkdir -p "$(dirname "$OUT")"
jq -s --argjson relay "${relay_rows:-[]}" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson max "$MAX_SEARCHES" '
  def usage(l): (map(select(.label == l))[0]) as $c | $c;
  {
    recorded_at: $date, search_cap: $max,
    note: "Live Tavily through the Bifrost relay. Credentials redacted (never recorded).",
    calls: map(del(.request)) | map(. as $c | $c + {gateway: ($relay | map(select(.request_id == $c.gateway_request_id))[0] // null | if . then del(.request_id) else null end)}),
    requests: map({label, request}),
    totals: {
      searches: map(select(.path == "/search")) | length,
      credits_reported: (map(.credits // 0) | add),
      bifrost_cost_usd: ($relay | map(.cost // 0) | add)
    }
  }' "$LIB_TMP/calls.jsonl" > "$OUT"
# usage bodies hold account totals; keep only the numbers.
for l in usage-before usage-after; do
  jq -c '{key_usage: .key.usage, search_usage: .key.search_usage, extract_usage: .key.extract_usage, plan_usage: .account.plan_usage, plan_limit: .account.plan_limit, paygo_usage: .account.paygo_usage}' "$LIB_TMP/$l.body" > "$LIB_TMP/$l.min" 2>/dev/null || echo null > "$LIB_TMP/$l.min"
done
jq --slurpfile b "$LIB_TMP/usage-before.min" --slurpfile a "$LIB_TMP/usage-after.min" '.usage = {before: $b[0], after: $a[0]}' "$OUT" > "$LIB_TMP/out.json" && mv "$LIB_TMP/out.json" "$OUT"

# Tavily keys start with tvly-; the only ones allowed are the two synthetic ones.
leaks=$(grep -ohE 'tvly-[A-Za-z0-9_-]{6,}' "$OUT" "$LOG" | grep -vxE 'tvly-mock|tvly-invalid-key-for-the-401-check' | grep -c . || true)
check "record and gateway log hold no Tavily key" "$leaks" 0
check "record holds no virtual key" "$(grep -cF -- "$VERIFIER" "$OUT" || true)" 0
check "searches within the cap" "$(( searches <= MAX_SEARCHES ))" 1
echo "wrote $OUT"
finish
