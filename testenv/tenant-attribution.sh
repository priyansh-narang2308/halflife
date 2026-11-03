#!/usr/bin/env bash
# Risk A, tenant attribution: when Halflife verifies tenant T's answer, whose
# budget pays for the Tavily search? Real gateway, mock Tavily, config
# testenv/configs/tenants. No real Tavily call.
#
# Three tenants (Acme, Globex, Initech), each a governance customer with an
# app key and a budget. Two verifier key layouts, side by side:
#
#   shared      one verifier key (vk-verifier, $0.04) for every tenant; the
#               tenant is named only in X-Project-ID
#   per-tenant  one verifier key per tenant (vk-verifier-<t>, $0.024 each),
#               inside the tenant's customer
#
# Measured, per verification: who was charged (budget usage in the config
# database), what Bifrost's relay log attributes it to, what Tavily saw
# (mock credits per X-Project-ID), and what happens when one tenant spends
# heavily. Writes testenv/results/tenant-attribution.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LOG="$ROOT/logs/tenant-attribution-gateway.log"
OUT="$ROOT/testenv/results/tenant-attribution.json"
: > "$LIB_TMP/calls.jsonl"

# verify layout tenant vk -> status; one basic search (1 credit) for tenant's answer
verify() {
  local status
  status=$(curl -s -m 10 -o "$LIB_TMP/last.body" -w '%{http_code}' -X POST "$GW/relay/tavily/search" \
    -H "x-bf-vk: $3" -H "X-Project-ID: vk-$2" -H "X-Session-Id: hlr_$1_$2" -H 'content-type: application/json' \
    -d "{\"query\":\"verify a claim for $2\",\"include_usage\":true}")
  jq -cn --arg layout "$1" --arg tenant "$2" --argjson status "$status" '{layout: $layout, tenant: $tenant, status: $status}' >> "$LIB_TMP/calls.jsonl"
  sleep 0.2 # governance charges a call asynchronously, after its reply
  echo "$status"
}
# verify_n layout tenant vk n -> statuses, space separated
verify_n() { local out=(); for _ in $(seq 1 "$4"); do out+=("$(verify "$1" "$2" "$3")"); done; echo "${out[*]}"; }
chat() {
  curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$GW/v1/chat/completions" -H "x-bf-vk: sk-bf-halflife-$1" \
    -H 'content-type: application/json' -d '{"model":"openai/ok","messages":[{"role":"user","content":"hello"}]}'
}
usage() { sqlite3 "$GATEWAY_APP/config.db" "select printf('%.3f', current_usage) from governance_budgets where id = '$1'"; }

require_free_ports
start_mock
start_mock_tavily
start_gateway tenants "$LOG"

echo "--- shared verifier key (\$0.04 for everyone)"
check "Acme 3, Globex 1: all allowed" "$(verify_n shared acme sk-bf-halflife-verifier 3) $(verify shared globex sk-bf-halflife-verifier)" "200 200 200 200"
check "Acme 2 more: the second hits the shared budget" "$(verify_n shared acme sk-bf-halflife-verifier 2)" "200 402"
check "Globex and Initech are now refused because of Acme's spend" \
  "$(verify shared globex sk-bf-halflife-verifier) $(verify shared initech sk-bf-halflife-verifier)" "402 402"

echo "--- per-tenant verifier keys (\$0.024 each, inside the tenant's customer)"
check "Acme 4: refused once its own budget is spent" "$(verify_n per-tenant acme sk-bf-halflife-verifier-acme 4)" "200 200 200 402"
check "Globex 2: unaffected by Acme" "$(verify_n per-tenant globex sk-bf-halflife-verifier-globex 2)" "200 200"
# Initech's customer budget ($0.016) is smaller than its verifier key's.
check "Initech 3: stopped by its customer budget (\$0.016) first" "$(verify_n per-tenant initech sk-bf-halflife-verifier-initech 3)" "200 200 402"
check "Acme and Globex apps still answer" "$(chat acme) $(chat globex)" "200 200"
check "Initech's app is refused: verification spent the customer budget they share" "$(chat initech)" 402

by_project=$(curl -s "$TAVILY/_mock/requests" | jq -c '.credits_by_project')
check "Tavily attributes every credit to its tenant (X-Project-ID), under both layouts" "$by_project" \
  '{"vk-acme":7,"vk-globex":3,"vk-initech":2}'

echo "--- who was charged"
stop_gateway # flushes budget usage and the relay log
check "shared key's budget: 5 searches (4 Acme, 1 Globex), no tenant budget touched" \
  "$(usage budget-verifier)/$(usage budget-app-acme)/$(usage budget-app-globex)" 0.040/0.000/0.000
check "per-tenant verifier budgets: Acme 3, Globex 2, Initech 2 searches" \
  "$(usage budget-verifier-acme)/$(usage budget-verifier-globex)/$(usage budget-verifier-initech)" 0.024/0.016/0.016
check "customer budgets: the same, from the per-tenant keys only" \
  "$(usage budget-cust-acme)/$(usage budget-cust-globex)/$(usage budget-cust-initech)" 0.024/0.016/0.016
check "app key budgets: never charged for verification" \
  "$(usage budget-app-acme)/$(usage budget-app-globex)/$(usage budget-app-initech)" 0.000/0.000/0.000

relay=$(sqlite3 -json "$GATEWAY_APP/logs.db" \
  "select virtual_key_id, coalesce(customer_id, '') as customer_id, coalesce(budget_ids, '') as budget_ids, status_code, coalesce(cost, 0) as cost from relay_logs order by timestamp")
check "relay log, shared key: no customer on any row (Bifrost cannot tell the tenants apart)" \
  "$(echo "$relay" | jq '[.[] | select(.virtual_key_id == "vk-verifier" and .customer_id != "")] | length')" 0
check "relay log, per-tenant keys: every row names the tenant's customer" \
  "$(echo "$relay" | jq -c '[.[] | select(.virtual_key_id | startswith("vk-verifier-")) | select(.customer_id != ("cust-" + (.virtual_key_id | ltrimstr("vk-verifier-"))))] | length')" 0
check "relay log, per-tenant charges by customer" \
  "$(echo "$relay" | jq -c 'map(select(.customer_id != "")) | group_by(.customer_id) | map({(.[0].customer_id): (map(.cost) | add * 1000 | round / 1000)}) | add')" \
  '{"cust-acme":0.024,"cust-globex":0.016,"cust-initech":0.016}'

mkdir -p "$(dirname "$OUT")"
budgets=$(sqlite3 -json "$GATEWAY_APP/config.db" "select id, max_limit, current_usage from governance_budgets order by id" \
  | jq -c 'map(.max_limit |= (. * 1e6 | round / 1e6) | .current_usage |= (. * 1e6 | round / 1e6))')
jq -s --argjson budgets "$budgets" --argjson tavily "$by_project" --argjson relay "$relay" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    recorded_at: $date,
    note: "Mock Tavily (1 credit per basic search, $0.008 per credit). Synthetic keys; values never recorded.",
    verifications: (group_by(.layout) | map({(.[0].layout): (group_by(.tenant) | map({(.[0].tenant): {allowed: map(select(.status == 200)) | length, refused: map(select(.status == 402)) | length}}) | add)}) | add),
    budgets: $budgets,
    tavily_credits_by_project: $tavily,
    relay_log_by_key: ($relay | group_by(.virtual_key_id) | map({(.[0].virtual_key_id): {customer: .[0].customer_id, budgets: (map(.budget_ids | select(. != "") | fromjson) | first // []), calls: length, cost: (map(.cost) | add * 1000 | round / 1000)}}) | add)
  }' "$LIB_TMP/calls.jsonl" > "$OUT"
echo "wrote $OUT"
finish
