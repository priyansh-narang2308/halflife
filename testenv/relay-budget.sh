#!/usr/bin/env bash
# Relay authorisation and budgets: Bifrost's governance decides who may reach
# the Tavily relay and stops a key's searches once its budget is spent. Real
# gateway, mock Tavily, config testenv/configs/relay-budget. No real Tavily call.
#
#   who may call       granted key 200; key without the grant 403; no key 401
#   budget             vk-verifier has $0.02 (2.5 basic searches): calls go
#                      through while spend < limit, then 402 before Tavily
#   charges            the budget's usage = credits Tavily reported x $0.008,
#                      and matches the relay log
#   concurrency        a burst of slow calls on a $0.02 budget: governance
#                      checks spend before a call and charges after it, so
#                      calls in flight together all pass, and the budget
#                      overshoots by up to concurrency x one call's cost
#
# Budget usage is read from the gateway's config database after shutdown,
# which flushes it (the governance API needs dashboard auth).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
VERIFIER=sk-bf-halflife-verifier     # synthetic; relay grant, $0.02 budget
BURST=sk-bf-halflife-verifier-burst  # synthetic; relay grant, $0.02 budget
SMOKE=sk-bf-halflife-smoke           # synthetic; no relay grant, $1 budget
RATE=0.008
BURST_SIZE=10
LOG="$ROOT/logs/relay-budget-gateway.log"

# search name vk [depth] -> $LIB_TMP/name.{status,body}
search() {
  local args=(-s -m 10 -o "$LIB_TMP/$1.body" -w '%{http_code}' -X POST "$GW/relay/tavily/search" -H 'content-type: application/json')
  [ -n "$2" ] && args+=(-H "x-bf-vk: $2")
  curl "${args[@]}" -d "{\"query\":\"budget $1\",\"include_usage\":true,\"search_depth\":\"${3:-basic}\"}" > "$LIB_TMP/$1.status"
  sleep 0.2 # governance charges a call asynchronously, after its reply
}
st()      { cat "$LIB_TMP/$1.status"; }
credits() { jq -r '.usage.credits // 0' "$LIB_TMP/$1.body"; }
now()     { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
reached() { curl -s "$TAVILY/_mock/requests" | jq '.searches'; }
usage()   { sqlite3 "$GATEWAY_APP/config.db" "select printf('%.3f', current_usage) from governance_budgets where id = '$1'"; }

require_free_ports
start_mock
start_mock_tavily
start_gateway relay-budget "$LOG"

echo "--- who may call the relay"
search granted "$VERIFIER"
check "granted key: 200" "$(st granted)" 200
search ungranted "$SMOKE"
check "key without a tavily grant (and money in its budget): 403 relay_blocked" "$(st ungranted)/$(jq -r .type "$LIB_TMP/ungranted.body")" 403/relay_blocked
search novk ""
check "no virtual key: 401" "$(st novk)" 401
check "refused calls never reached Tavily" "$(reached)" 1

echo "--- a \$0.02 budget"
# Spend so far: 1 credit ($0.008). Each call is checked against spend before it.
search second "$VERIFIER"
check "spend 0.008 < 0.02: allowed" "$(st second)" 200
search third "$VERIFIER" advanced
check "spend 0.016 < 0.02: allowed (an advanced search, 2 credits)" "$(st third)" 200
before=$(reached)
search fourth "$VERIFIER"
check "spend 0.032 >= 0.02: 402 budget_exceeded" "$(st fourth)/$(jq -r .type "$LIB_TMP/fourth.body")" 402/budget_exceeded
check "the refused search never reached Tavily" "$(reached)" "$before"
usage_status=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$GW/relay/tavily/usage" -H "x-bf-vk: $VERIFIER")
check "the free GET /usage is refused too (every relay call is evaluated)" "$usage_status" 402
search other "$BURST"
check "another key's budget is untouched: 200" "$(st other)" 200
spent=$(for c in granted second third; do credits "$c"; done | paste -sd+ - | bc)

echo "--- a burst of $BURST_SIZE concurrent calls on a \$0.02 budget"
# vk-verifier-burst has spent 1 credit (the call above), so one at a time 2
# more calls would pass. Each burst call waits 500 ms upstream (live Tavily
# took 1.1-2.8 s), so all of them are in flight together.
pids=()
t0=$(now)
for i in $(seq 1 "$BURST_SIZE"); do
  curl -s -m 10 -o /dev/null -w '%{http_code}\n' -X POST "$GW/relay/tavily/search" -H "x-bf-vk: $BURST" \
    -H 'content-type: application/json' -d "{\"query\":\"burst $i [mock:slow-500]\",\"include_usage\":true}" > "$LIB_TMP/burst.$i" &
  pids+=($!)
done
wait "${pids[@]}" # not a bare wait: the mocks and the gateway are background jobs too
wall=$(echo "$(now) - $t0" | bc)
burst_ok=$(cat "$LIB_TMP"/burst.* | grep -c '^200$' || true)
echo "burst: $burst_ok of $BURST_SIZE allowed in ${wall}s (one at a time, 2 would pass)"
check "the calls overlapped (wall time under 2 x 500 ms)" "$(echo "$wall < 1" | bc)" 1
# Governance checks spend before a call and charges after its reply; nothing
# is reserved for calls in flight, so every call that starts under the limit
# passes. The overshoot is bounded by concurrency x the cost of one call.
check "concurrent calls all pass: the budget overshoots" "$burst_ok" "$BURST_SIZE"
sleep 0.5
search after "$BURST"
check "once charged, the overshot budget refuses: 402" "$(st after)" 402

echo "--- what was charged"
stop_gateway # flushes budget usage and the relay log
check "vk-verifier budget = $spent credits x $RATE" "$(usage budget-verifier)" "$(printf '%.3f' "$(echo "$spent * $RATE" | bc)")"
check "vk-verifier budget = its relay log cost" "$(usage budget-verifier)" \
  "$(sqlite3 "$GATEWAY_APP/logs.db" "select printf('%.3f', sum(cost)) from relay_logs where virtual_key_id = 'vk-verifier'")"
check "vk-verifier-burst budget = (1 + $burst_ok) x $RATE (the overshoot is charged, not lost)" "$(usage budget-verifier-burst)" \
  "$(printf '%.3f' "$(echo "(1 + $burst_ok) * $RATE" | bc)")"
check "vk-smoke budget untouched by its refused call" "$(usage budget-smoke)" 0.000
check "refusals carry no cost in the relay log" \
  "$(sqlite3 "$GATEWAY_APP/logs.db" "select count(*) from relay_logs where status_code >= 400 and coalesce(cost, 0) > 0")" 0

finish
