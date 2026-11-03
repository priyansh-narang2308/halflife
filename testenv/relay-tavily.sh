#!/usr/bin/env bash
# Tavily relay contract: Halflife's evidence searches go through Bifrost's
# relay (/relay/tavily/...), not straight to Tavily. Real gateway, mock Tavily
# (testenv/mocktavily), config testenv/configs/relay. No real Tavily call.
#
# Checks three sides of the relay:
#   what reaches Tavily   the relay's credential replaces the caller's; the
#                         virtual key and other caller credentials are
#                         stripped; attribution headers pass through
#   what the caller gets  Tavily's body, status and Retry-After unchanged;
#                         grants and routes enforced by the gateway
#   what Bifrost charges  cost = usage.credits x cost_per_unit, per call,
#                         from the gateway's relay log
# Then runs Halflife's own Tavily client against the same relay
# (TestTavilyRelayContract in plugins/halflife).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
VERIFIER=sk-bf-halflife-verifier # synthetic; holds the relay grant
SMOKE=sk-bf-halflife-smoke       # synthetic; no relay grant
RATE=0.008                       # USD per Tavily credit (pay-as-you-go, docs.tavily.com/documentation/api-credits)
LOG="$ROOT/logs/relay-tavily-gateway.log"

# relay name vk path body [header...] -> $LIB_TMP/name.{status,headers,body}
relay() {
  local name=$1 vk=$2 path=$3 body=$4; shift 4
  local args=(-s -m 10 -D "$LIB_TMP/$name.headers" -o "$LIB_TMP/$name.body" -w '%{http_code}' -X POST "$GW/relay/tavily$path" -H 'content-type: application/json')
  [ -n "$vk" ] && args+=(-H "x-bf-vk: $vk")
  for h in "$@"; do args+=(-H "$h"); done
  curl "${args[@]}" -d "$body" > "$LIB_TMP/$name.status"
}
st()   { cat "$LIB_TMP/$1.status"; }
hdr()  { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
seen() { curl -s "$TAVILY/_mock/requests" | jq -r ".last.$1"; }
mockcount() { curl -s "$TAVILY/_mock/requests" | jq -r '.searches + .extracts'; }

require_free_ports
start_mock
start_mock_tavily
start_gateway relay "$LOG"

echo "--- what reaches Tavily"
relay basic "$VERIFIER" /search '{"query":"How much does the Acme Cloud Pro plan cost?","include_usage":true}' \
  'X-Project-ID: vk-smoke' 'X-Session-Id: hlr_contract' 'Authorization: Bearer caller-secret' 'X-Api-Key: caller-key'
check "granted key: 200 (the caller's Authorization was replaced by the relay credential)" "$(st basic)" 200
check "virtual key stripped" "$(seen x_bf_vk_present)" false
check "caller's X-Api-Key stripped" "$(seen x_api_key_present)" false
check "X-Project-ID (tenant) forwarded" "$(seen x_project_id)" vk-smoke
check "X-Session-Id (report) forwarded" "$(seen x_session_id)" hlr_contract
check "include_usage forwarded in the body" "$(seen include_usage)" true

echo "--- what the caller gets"
check "Tavily's body unchanged (usage.credits)" "$(jq -c '[.usage.credits, (.results | length), (.request_id | startswith("mock-"))]' "$LIB_TMP/basic.body")" '[1,2,true]'
check "gateway request id on the reply" "$(hdr basic x-bifrost-request-id | grep -c .)" 1
check "no Halflife status on relay replies (not an answer)" "$(hdr basic x-halflife-status | grep -c . || true)" 0
relay advanced "$VERIFIER" /search '{"query":"q advanced","include_usage":true,"search_depth":"advanced"}'
check "advanced search: 2 credits" "$(st advanced)/$(jq .usage.credits "$LIB_TMP/advanced.body")" 200/2
relay extract "$VERIFIER" /extract '{"urls":["https://a.example/1","https://a.example/2","https://a.example/3","https://a.example/4","https://a.example/5","https://a.example/mock-fail"],"include_usage":true}'
check "extract: 5 fetched, 1 failed, 1 credit" "$(st extract)/$(jq -c '[(.results|length), (.failed_results|length), .usage.credits]' "$LIB_TMP/extract.body")" '200/[5,1,1]'
relay nousage "$VERIFIER" /search '{"query":"q without usage"}'
check "search without include_usage: 200, no usage block" "$(st nousage)/$(jq -c .usage "$LIB_TMP/nousage.body")" 200/null
relay e432 "$VERIFIER" /search '{"query":"q [mock:432]","include_usage":true}'
check "plan limit: 432 and Tavily's message passed through" "$(st e432)/$(jq -r .detail.error "$LIB_TMP/e432.body" | cut -c1-40)" "432/This request exceeds your plan's set usa"
relay e429 "$VERIFIER" /search '{"query":"q [mock:429]","include_usage":true}'
check "rate limit: 429 with Retry-After" "$(st e429)/$(hdr e429 retry-after)" 429/2
usage_status=$(curl -s -m 10 -o "$LIB_TMP/usage.body" -w '%{http_code}' "$GW/relay/tavily/usage" -H "x-bf-vk: $VERIFIER")
# Tavily bills the search without include_usage too (1 credit): 1 + 2 + 1 + 1.
check "GET /usage relayed (free route): Tavily counts 5 credits" "$usage_status/$(jq .key.usage "$LIB_TMP/usage.body")" 200/5

echo "--- what the gateway enforces"
before=$(mockcount)
relay ungranted "$SMOKE" /search '{"query":"q","include_usage":true}'
check "key without a relay grant: 403" "$(st ungranted)" 403
relay novk "" /search '{"query":"q","include_usage":true}'
check "no virtual key: 401" "$(st novk)" 401
relay crawl "$VERIFIER" /crawl '{"url":"https://a.example"}'
check "route not in the contract (crawl): 404" "$(st crawl)/$(jq -r .error.message "$LIB_TMP/crawl.body")" '404/no route for POST /crawl on relay "tavily"'
check "none of the refused calls reached Tavily" "$(mockcount)" "$before"

echo "--- Halflife's Tavily client against the relay"
if (cd "$ROOT/bifrost/plugins/halflife" && HALFLIFE_RELAY_GATEWAY="$GW" HALFLIFE_RELAY_VK="$VERIFIER" HALFLIFE_RELAY_MOCK="$TAVILY" \
  GOWORK=off go test -count=1 -run '^TestTavilyRelayContract$' -v . > "$LIB_TMP/client.out" 2>&1); then
  check "TestTavilyRelayContract" "$(grep -c '^--- PASS: TestTavilyRelayContract' "$LIB_TMP/client.out")" 1
else
  sed 's/^/  /' "$LIB_TMP/client.out" | tail -20
  check "TestTavilyRelayContract" fail pass
fi

echo "--- what Bifrost charges (relay log)"
stop_gateway # flushes the request log
rows=$(sqlite3 -separator ' ' "$GATEWAY_APP/logs.db" \
  "select method||' '||path, status_code, coalesce(units,'-'), case when cost is null then '-' else printf('%.3f', cost) end, virtual_key_id from relay_logs order by timestamp")
echo "relay log:"; echo "$rows" | sed 's/^/  /'
# The script's calls, then the client test's (basic, advanced, extract, 432,
# 429, ungranted). Refused routes and unknown relays never reach the relay
# log; a request without a virtual key does, with no key.
check "charged per call: credits x $RATE; errors and refusals uncharged" "$(echo "$rows" | tr '\n' ';')" \
"POST /search 200 1.0 0.008 vk-verifier;\
POST /search 200 2.0 0.016 vk-verifier;\
POST /extract 200 1.0 0.008 vk-verifier;\
POST /search 200 - 0.000 vk-verifier;\
POST /search 432 - - vk-verifier;\
POST /search 429 - - vk-verifier;\
GET /usage 200 - - vk-verifier;\
POST /search 403 - - vk-smoke;\
POST /search 401 - - ;\
POST /search 200 1.0 0.008 vk-verifier;\
POST /search 200 2.0 0.016 vk-verifier;\
POST /extract 200 1.0 0.008 vk-verifier;\
POST /search 432 - - vk-verifier;\
POST /search 429 - - vk-verifier;\
POST /search 403 - - vk-smoke;"
# The gap: Tavily billed the search sent without include_usage, Bifrost
# charged nothing for it. Halflife's client always sets include_usage.
billed=$(sqlite3 "$GATEWAY_APP/logs.db" "select printf('%.3f', sum(cost)) from relay_logs")
check "Bifrost charged 0.064 = 8 credits; Tavily counted 9 (the no-usage search is the gap)" \
  "$billed/$(curl -s "$TAVILY/_mock/requests" | jq .credits)" 0.064/9
check "relay log holds no credential (virtual key or Tavily key)" \
  "$(sqlite3 "$GATEWAY_APP/logs.db" .dump | grep -c -e "$VERIFIER" -e tvly-mock -e caller-secret -e caller-key || true)" 0

finish
