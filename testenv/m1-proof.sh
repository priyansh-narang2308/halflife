#!/usr/bin/env bash
# M1 end-to-end proof, one script: a tenant's request goes through Bifrost,
# Halflife captures the answer, verifies one claim on Tavily through the
# governed relay with the tenant's verifier key, and serves the report.
# Checks every M1 exit criterion that a running gateway can show (A, B, D, E
# and tenant attribution); the cache lifecycle (C) is `make cache`.
#
#   default   mock LLM and mock Tavily; no external call
#   LIVE=1    the tenants' first questions are answered by a free OpenRouter
#             model, and every search goes to real Tavily. Spend is capped by
#             the verifier keys' own Bifrost budgets: 2 searches each, so at
#             most 4 credits ($0.032). Needs OPENROUTER_API_KEY and
#             TAVILY_API_KEY in .env; the script never reads either, only
#             the gateway does.
#
# Writes testenv/results/m1-{mock,live}.json: statuses, timings, claims,
# source URLs, titles and dates, and Bifrost's charges. No page text and no
# credential.
set -Eeuo pipefail
trap 'echo "m1-proof.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LIVE="${LIVE:-}"
MODE=$([ -n "$LIVE" ] && echo live || echo mock)
LOG="$ROOT/logs/m1-proof-$MODE-gateway.log"
OUT="$ROOT/testenv/results/m1-$MODE.json"
TOKEN=halflife-test-setup-token # synthetic, from the config
RATE=0.008
GUARD_CALLS=20
ANSWER_MODEL=google/gemma-4-31b-it:free # free on OpenRouter (listed 3 Nov 2026)
# Free models are rate-limited upstream (a 429 on the first live run), so the
# answer request carries Bifrost fallbacks to two more free models.
FALLBACK_MODELS="xingchen-agi/xing4.0-29b-a4b:free openrouter/free"
PRICE_Q="How much does the Acme Cloud Pro plan cost?"
SDK_Q="What is the latest version of the Acme SDK?"
CEO_Q="Who is the CEO of Acme Cloud?"

CONFIG="$LIB_TMP/m1.json"
if [ -n "$LIVE" ]; then
  for k in OPENROUTER_API_KEY TAVILY_API_KEY; do
    grep -q "^$k=." "$ROOT/.env" 2>/dev/null || { echo "$k is not set in .env" >&2; exit 1; }
  done
  Q_A="What is the latest stable version of the Go programming language? Answer in one sentence."
  Q_B="Who is the current CEO of OpenAI? Answer in one sentence."
  MODEL_A="openrouter/$ANSWER_MODEL"
  FB_A=$(for m in $FALLBACK_MODELS; do printf 'openrouter/%s,' "$m"; done | sed 's/,$//')
  jq --arg m "$ANSWER_MODEL" --arg fbs "$FALLBACK_MODELS" '
    .providers.openrouter = {keys: [{name: "openrouter", value: "env.OPENROUTER_API_KEY", models: ([$m] + ($fbs | split(" "))), weight: 1.0}],
                             network_config: {default_request_timeout_in_seconds: 90, max_retries: 1}}
    | (.governance.virtual_keys[] | select(.id == "vk-acme" or .id == "vk-globex") | .provider_configs)
        += [{provider: "openrouter", allowed_models: ([$m] + ($fbs | split(" "))), key_ids: ["*"], weight: 1.0}]
    | (.governance.budgets[] | select(.id == "budget-verifier-globex") | .max_limit) = 0.016
    | (.relays[] | select(.name == "tavily")) |= (.base_url = "https://api.tavily.com" | .credential.value = "env.TAVILY_API_KEY")
  ' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"
else
  Q_A="$PRICE_Q" Q_B="$PRICE_Q" MODEL_A=openai/ok FB_A=
  cp "$ROOT/testenv/configs/m1/config.json" "$CONFIG"
fi

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
hdr() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
# ask name key model question [fallback,...] -> $LIB_TMP/name.{headers,body,status,done_ms}
ask() {
  local body
  body=$(jq -cn --arg m "$3" --arg q "$4" --arg fb "${5:-}" \
    '{model: $m, max_tokens: 300, messages: [{role: "user", content: $q}]} + (if $fb == "" then {} else {fallbacks: ($fb | split(","))} end)')
  curl -s -m 120 -D "$LIB_TMP/$1.headers" -o "$LIB_TMP/$1.body" -w '%{http_code} %{time_total}' -X POST "$GW/v1/chat/completions" \
    -H "x-bf-vk: $2" -H 'content-type: application/json' -d "$body" > "$LIB_TMP/$1.out"
  cut -d' ' -f1 "$LIB_TMP/$1.out" > "$LIB_TMP/$1.status"
  cut -d' ' -f2 "$LIB_TMP/$1.out" > "$LIB_TMP/$1.seconds"
  now_ms > "$LIB_TMP/$1.done_ms"
  echo "$1: $(cat "$LIB_TMP/$1.status") report=$(hdr "$1" x-halflife-report) status=$(hdr "$1" x-halflife-status)"
}
# report name -> $LIB_TMP/name.json once complete (up to 30 s); prints its HTTP status
report() {
  local id status=none; id=$(hdr "$1" x-halflife-report)
  [ -n "$id" ] || { echo none; return; }
  for _ in $(seq 1 300); do
    status=$(curl -s -m 5 -o "$LIB_TMP/$1.json" -w '%{http_code}' "$GW/api/halflife/reports/$id" -H "X-Bifrost-Setup-Token: $TOKEN")
    [ "$status" != 200 ] && break
    [ "$(jq -r .status "$LIB_TMP/$1.json")" = complete ] && break
    sleep 0.1
  done
  echo "$status"
}
r() { jq -c "$2" "$LIB_TMP/$1.json"; }
completed_after_response() { # the audit finished after the client had its answer
  local done; done=$(jq -r '.completed_at' "$LIB_TMP/$1.json")
  python3 -c "import sys,datetime;d=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'));print(int(d.timestamp()*1000) > int(sys.argv[2]))" "$done" "$(cat "$LIB_TMP/$1.done_ms")"
}
captured() { grep -c '"halflife: captured ' "$LOG" || true; }

require_free_ports
start_mock
# Held 1 s like a live search, so the audit visibly runs after the response.
[ -z "$LIVE" ] && start_mock_tavily -search-delay 1s
start_gateway "$CONFIG" "$LOG"
echo "mode: $MODE"

echo "--- A. the plugin is built in and loaded"
check "startup log: Halflife initialized with 2 tenant verifier keys" \
  "$(grep -c '"halflife: initialized (.*verifiers=2 gateway=http://127.0.0.1:8090' "$LOG")" 1

# First, while the verifier key's budget is unspent: a spent key is refused
# for LLM calls too (checked under D).
echo "--- E. recursion guard: $GUARD_CALLS requests on a verifier key"
before=$(captured)
guard_ok=0
for i in $(seq 1 "$GUARD_CALLS"); do
  ask "guard$i" sk-bf-halflife-verifier-acme openai/ok "$PRICE_Q" >/dev/null
  [ "$(cat "$LIB_TMP/guard$i.status")/$(hdr "guard$i" x-halflife-status)/$(hdr "guard$i" x-halflife-report)" = "200/not-audited; reason=verifier/" ] && guard_ok=$((guard_ok + 1))
done
[ "$guard_ok" = "$GUARD_CALLS" ] || echo "  first guard reply: $(cat "$LIB_TMP/guard1.status") $(hdr guard1 x-halflife-status)"
check "all $GUARD_CALLS answered, marked not-audited (verifier), no report" "$guard_ok" "$GUARD_CALLS"
check "captures during the guard run: 0" "$(( $(captured) - before ))" 0

echo "--- B. capture, report header, audit after the response"
ask acme sk-bf-halflife-acme "$MODEL_A" "$Q_A" "$FB_A"
check "Acme's answer: 200, queued, report ID" "$(cat "$LIB_TMP/acme.status")/$(hdr acme x-halflife-status)/$(hdr acme x-halflife-report | cut -c1-4)" 200/queued/hlr_
check "the answer is an ordinary chat completion" "$(jq -r '.choices[0].message.content | length > 0' "$LIB_TMP/acme.body")" true
check "report served and complete" "$(report acme)/$(r acme .status)" '200/"complete"'
check "the audit finished after the client had its answer" "$(completed_after_response acme)" True
echo "Acme: answer in $(cat "$LIB_TMP/acme.seconds") s, report complete $(r acme '((.completed_at | sub("\\.[0-9]+"; "") | fromdateiso8601) - (.created_at | sub("\\.[0-9]+"; "") | fromdateiso8601))') s after it was queued"
check "report linked to the gateway request" "$(r acme .request_id)" "\"$(hdr acme x-bifrost-request-id)\""
check "report holds the answer the client received" "$(r acme .answer.text)" "$(jq -c '.choices[0].message.content' "$LIB_TMP/acme.body")"
ask fallback sk-bf-halflife-acme openai/fail-500 "$SDK_Q" openai/ok
check "fallback: one report, of the answer that was served" \
  "$(report fallback)/$(r fallback '[.answer.model, .answer.is_fallback]')" '200/["ok",true]'

echo "--- D. Tavily through the relay, priced and budgeted"
budget_q_status=$(ask budget sk-bf-halflife-acme openai/ok "$CEO_Q" >/dev/null; report budget)
acme_outcomes="$(r acme .outcome) $(r fallback .outcome)"
echo "Acme outcomes: $acme_outcomes"
searched=$(jq -s '[.[] | select(.evidence.credits != null and .evidence.reused == false)] | length' "$LIB_TMP/acme.json" "$LIB_TMP/fallback.json")
if [ "$searched" = 2 ]; then
  check "Acme's third claim: its 2-search verifier budget is spent (402, not retried)" "$budget_q_status/$(r budget .outcome)" '200/"budget_exhausted"'
else
  echo "NOTE  Acme made $searched searches before the third claim (no claim or no evidence earlier), so the budget was not reached"
fi
ask spent sk-bf-halflife-verifier-acme openai/ok "$PRICE_Q" >/dev/null
check "the spent verifier key is refused for LLM calls too: one budget covers searches and the judge" "$(cat "$LIB_TMP/spent.status")" 402
ungranted=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$GW/relay/tavily/search" -H 'x-bf-vk: sk-bf-halflife-acme' -H 'content-type: application/json' -d '{"query":"q","include_usage":true}')
novk=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$GW/relay/tavily/search" -H 'content-type: application/json' -d '{"query":"q","include_usage":true}')
check "relay refuses Acme's app key (no grant) and a keyless call" "$ungranted/$novk" 403/401

echo "--- F. tenants: each verification charged to its own tenant"
ask globex sk-bf-halflife-globex "$MODEL_A" "$Q_B" "$FB_A"
check "Globex's report: its own verifier key" "$(report globex)/$(r globex '.evidence.verifier_virtual_key_id // .outcome')" '200/"vk-verifier-globex"'
ask initech sk-bf-halflife-initech openai/ok "$PRICE_Q" >/dev/null
check "Initech has no verifier key: not verified, nothing spent" "$(report initech)/$(r initech '[.outcome, .evidence]')" '200/["no_verifier_key",null]'

echo "--- G. the report endpoint"
check "without the setup token: 401" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/reports/$(hdr acme x-halflife-report)")" 401
check "unknown report: 404" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/reports/hlr_unknown" -H "X-Bifrost-Setup-Token: $TOKEN")" 404

echo "--- what Bifrost charged"
names=(acme fallback budget globex initech)
stop_gateway # flushes the relay log and budget usage
relay=$(sqlite3 -json "$GATEWAY_APP/logs.db" "select request_id, virtual_key_id, customer_id, status_code, units, cost, latency, upstream_latency, overhead_latency from relay_logs where path = '/search' order by timestamp" || echo '[]')
relay=${relay:-[]}
mismatch=0
for n in "${names[@]}"; do
  gid=$(jq -r '.evidence.gateway_request_id // ""' "$LIB_TMP/$n.json")
  [ -n "$gid" ] || continue
  row=$(echo "$relay" | jq -c --arg id "$gid" 'map(select(.request_id == $id))[0]')
  want=$(jq -r --arg rate "$RATE" '"\(.tenant.virtual_key_id | sub("^vk-"; "vk-verifier-")) \(.tenant.virtual_key_id | sub("^vk-"; "cust-")) \((.evidence.credits * ($rate | tonumber) * 1000 | round) / 1000)"' "$LIB_TMP/$n.json")
  got=$(echo "$row" | jq -r '"\(.virtual_key_id) \(.customer_id) \((.cost * 1000 | round) / 1000)"')
  [ "$got" = "$want" ] || { echo "  $n: relay log '$got', report says '$want'"; mismatch=$((mismatch + 1)); }
done
check "every report's search is in the relay log on the tenant's verifier key and customer, at credits x $RATE" "$mismatch" 0
check "refused calls never charged" "$(echo "$relay" | jq '[.[] | select(.status_code >= 400 and (.cost // 0) > 0)] | length')" 0
budgets=$(sqlite3 -json "$GATEWAY_APP/config.db" "select id, max_limit, current_usage from governance_budgets where id like 'budget-verifier-%' or id like 'budget-cust-%' order by id" \
  | jq -c 'map(.max_limit |= (. * 1e6 | round / 1e6) | .current_usage |= (. * 1e6 | round / 1e6))')
check "audits: every captured answer audited, none failed" \
  "$(grep -o 'audited=[0-9]* failed=[0-9]*' "$LOG" | tail -1)" "audited=$(( ${#names[@]} )) failed=0"

mkdir -p "$(dirname "$OUT")"
for n in "${names[@]}"; do
  jq -c --arg name "$n" --arg status "$(cat "$LIB_TMP/$n.status")" '{
      name: $name, http_status: ($status | tonumber), report_id: .id, request_id, tenant: .tenant.virtual_key_id,
      model: .answer.model, is_fallback: .answer.is_fallback, question: .answer.question, answer: .answer.text,
      outcome, verdict, claim, error,
      evidence: (.evidence | if . == null then null else {verifier_virtual_key_id, credits, reused, gateway_request_id,
        tavily_request_id, sources: [.sources[] | {title, url, published_date, score}]} end),
      seconds_to_report: (((.completed_at | sub("\\.[0-9]+"; "") | fromdateiso8601) - (.created_at | sub("\\.[0-9]+"; "") | fromdateiso8601)))
    }' "$LIB_TMP/$n.json"
done | jq -s --arg mode "$MODE" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg model "$ANSWER_MODEL" \
  --argjson relay "$relay" --argjson budgets "$budgets" --argjson guard "$guard_ok" --argjson guard_calls "$GUARD_CALLS" '{
    recorded_at: $date, mode: $mode,
    answer_model: (if $mode == "live" then $model else "mock" end), tavily: (if $mode == "live" then "api.tavily.com" else "mock" end),
    note: "Synthetic keys; no credential and no page text recorded. Source URLs, titles and dates only.",
    reports: .,
    recursion_guard: {calls: $guard_calls, marked_verifier: $guard, captured: 0},
    relay_searches: ($relay | map(del(.request_id) + {gateway_request_id: .request_id})),
    budgets: $budgets,
    totals: {searches_charged: ($relay | map(select(.status_code == 200)) | length), credits: ($relay | map(.units // 0) | add // 0), bifrost_cost_usd: ($relay | map(.cost // 0) | add // 0 | . * 1000 | round / 1000)}
  }' > "$OUT"

# Only synthetic credentials may appear anywhere we write.
leaks=$(grep -ohE 'tvly-[A-Za-z0-9_-]{6,}|sk-or-[A-Za-z0-9_-]{6,}' "$OUT" "$LOG" | grep -vxE 'tvly-mock|tvly-invalid-key-for-the-401-check' | grep -c . || true)
check "record and gateway log hold no Tavily or OpenRouter key" "$leaks" 0
check "record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
