#!/usr/bin/env bash
# Minimal verifier and report endpoint, through the real gateway: a tenant's
# answer is captured, one claim is searched on Tavily through the relay with
# that tenant's verifier key (D37), and the report is served at
# GET /api/halflife/reports/{id}. Mock LLM, mock Tavily, config
# testenv/configs/verify. No real Tavily or LLM call.
#
# Tenants: Acme and Globex have verifier keys (Acme's budget: 2 searches);
# Initech has none. /api calls carry the config's synthetic setup token, as
# every /api call must while the dashboard has no admin account.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LOG="$ROOT/logs/verify-report-gateway.log"
TOKEN=halflife-test-setup-token # synthetic, from the config
PRICE_Q="How much does the Acme Cloud Pro plan cost?"
SDK_Q="What is the latest version of the Acme SDK?"
CEO_Q="Who is the CEO of Acme Cloud?"

# ask name tenant question -> $LIB_TMP/name.{headers,body}; prints the report ID
ask() {
  curl -s -m 10 -D "$LIB_TMP/$1.headers" -o "$LIB_TMP/$1.body" -X POST "$GW/v1/chat/completions" \
    -H "x-bf-vk: sk-bf-halflife-$2" -H 'content-type: application/json' \
    -d "$(jq -cn --arg q "$3" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')"
  hdr "$1" x-halflife-report
}
hdr() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
# report id -> $LIB_TMP/id.json once complete (waits up to 5 s); prints its HTTP status
report() {
  local status
  for _ in $(seq 1 50); do
    status=$(curl -s -m 5 -o "$LIB_TMP/$1.json" -w '%{http_code}' "$GW/api/halflife/reports/$1" -H "X-Bifrost-Setup-Token: $TOKEN")
    [ "$status" = 200 ] && [ "$(jq -r .status "$LIB_TMP/$1.json")" = complete ] && break
    [ "$status" != 200 ] && break
    sleep 0.1
  done
  echo "$status"
}
r() { jq -c "$2" "$LIB_TMP/$1.json"; }
searches() { curl -s "$TAVILY/_mock/requests" | jq .searches; }

require_free_ports
start_mock
start_mock_tavily
start_gateway verify "$LOG"
check "startup log names the two verifier keys and the gateway" \
  "$(grep -c 'verifiers=2 gateway=http://127.0.0.1:8090' "$LOG")" 1

echo "--- Acme: a priced claim"
price=$(ask price acme "$PRICE_Q")
check "answer queued with a report ID" "$(hdr price x-halflife-status)/$(echo "$price" | cut -c1-4)" queued/hlr_
check "report served once complete" "$(report "$price")/$(r "$price" '[.status, .outcome, .verdict]')" '200/["complete","evidence_found","not_judged"]'
check "report linked to the gateway request" "$(r "$price" .request_id)" "\"$(hdr price x-bifrost-request-id)\""
check "tenant recorded by key ID and name" "$(r "$price" .tenant)" '{"virtual_key_id":"vk-acme","virtual_key_name":"Acme app"}'
check "claim is the answer's priced sentence, searched as is" "$(r "$price" '.claim.text == .answer.text and .claim.query == .claim.text')" true
check "evidence: Acme's verifier key, 1 basic credit, fresh search" \
  "$(r "$price" '.evidence | [.verifier_virtual_key_id, .search_depth, .credits, .reused]')" '["vk-verifier-acme","basic",1,false]'
check "sources stored with URL, date and snippet" \
  "$(r "$price" '[.evidence.sources[] | .url, .published_date] | join(" ")')" \
  '"https://acme.example/pricing 2026-10-01 https://news.example/acme-pro-price 2026-09-15"'
check "Tavily saw the tenant and the report ID" "$(curl -s "$TAVILY/_mock/requests" | jq -c '.last | [.x_project_id, .x_session_id]')" "[\"vk-acme\",\"$price\"]"

echo "--- repeats, other claims, other tenants"
before=$(searches)
again=$(ask again acme "$PRICE_Q")
check "same answer again: new report, search reused, no new credits" \
  "$(report "$again")/$(r "$again" '.evidence | [.reused, .credits, (.sources | length)]')/$(searches)" "200/[true,0,2]/$before"
sdk=$(ask sdk acme "$SDK_Q")
check "second claim (a version): evidence found" "$(report "$sdk")/$(r "$sdk" '[.outcome, .evidence.sources[0].url]')" '200/["evidence_found","https://code.example/acme/acme-sdk/releases"]'
ceo=$(ask ceo acme "$CEO_Q")
check "third claim: Acme's verifier budget (2 searches) is spent" \
  "$(report "$ceo")/$(r "$ceo" '[.outcome, (.error | test("402"))]')" '200/["budget_exhausted",true]'
globex=$(ask globex globex "$PRICE_Q")
check "Globex, same question: its own key and its own search" \
  "$(report "$globex")/$(r "$globex" '.evidence | [.verifier_virtual_key_id, .reused, .credits]')" '200/["vk-verifier-globex",false,1]'
initech=$(ask initech initech "$PRICE_Q")
check "Initech has no verifier key: claim recorded, nothing spent" \
  "$(report "$initech")/$(r "$initech" '[.outcome, (.claim != null), .evidence]')" '200/["no_verifier_key",true,null]'
chatty=$(ask chatty acme "Tell me something nice")
check "an answer with nothing checkable: no claim, no search" "$(report "$chatty")/$(r "$chatty" '[.outcome, .claim]')" '200/["no_claim",null]'

echo "--- the endpoint"
check "without the setup token: 401" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/reports/$price")" 401
check "unknown report: 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/reports/hlr_unknown" -H "X-Bifrost-Setup-Token: $TOKEN")" 404
check "reports hold no key value" "$(cat "$LIB_TMP"/hlr_*.json | grep -c 'sk-bf-' || true)" 0

echo "--- what was charged"
gw_id=$(jq -r .evidence.gateway_request_id "$LIB_TMP/$price.json")
stop_gateway # flushes budget usage and the relay log
check "the report's relay call is in the relay log, on Acme's key and customer" \
  "$(sqlite3 -separator ' ' "$GATEWAY_APP/logs.db" "select virtual_key_id, customer_id, printf('%.3f', cost) from relay_logs where request_id = '$gw_id'")" \
  "vk-verifier-acme cust-acme 0.008"
check "budgets: Acme verifier and customer 2 searches, Globex 1" \
  "$(for b in budget-verifier-acme budget-cust-acme budget-verifier-globex budget-cust-initech; do sqlite3 "$GATEWAY_APP/config.db" "select printf('%.3f', current_usage) from governance_budgets where id = '$b'"; done | paste -sd/ -)" \
  0.016/0.016/0.008/0.000
check "audits: 7 captured, none failed" "$(grep -o 'audited=[0-9]* failed=[0-9]*' "$LOG" | tail -1)" "audited=7 failed=0"

finish
