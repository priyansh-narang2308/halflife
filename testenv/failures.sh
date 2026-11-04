#!/usr/bin/env bash
# Failure handling through the real gateway, against mock Tavily's scripted
# faults (fixtures/tavily.json "faults") and Acme's and Globex's verifier
# budgets. Each Hooli question yields one claim whose search meets a fault:
#
#   429, Retry-After 1    waited out, retried once, checked
#   429, Retry-After 8    not waited for: the Tavily circuit opens for 8 s;
#                         the next audit makes no call (verifier_unavailable)
#                         and the first after 8 s probes and closes it
#   432                   credits exhausted: the circuit opens for the credits
#                         cooldown (3 s here) without counting failures
#   500, 500              the retry fails too: 2 consecutive failures open the
#                         circuit (threshold 2), cooldown 3 s
#   2.5 s delay           the search times out at search_timeout_seconds (1)
#   402 (Globex)          the verifier budget is spent mid-audit: Globex's audits pause
#                         for the budget backoff with no call; Acme's go on
#
# Then GET /api/halflife/metrics and /usage report the same events. Mock LLM
# and mock Tavily only; no external call. Writes testenv/results/failures-mock.json.
set -Eeuo pipefail
trap 'echo "failures.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LOG="$ROOT/logs/failures-gateway.log"
OUT="$ROOT/testenv/results/failures-mock.json"
TOKEN=halflife-test-setup-token # synthetic, from the config

CONFIG="$LIB_TMP/failures.json"
jq '
  (.governance.budgets[] | select(.id == "budget-verifier-acme") | .max_limit) = 1
  | (.governance.budgets[] | select(.id == "budget-verifier-globex") | .max_limit) = 0.008
  | (.plugins[] | select(.name == "halflife") | .config) += {verifier_models: ["openai/ok"],
      circuit_breaker_failures: 2, circuit_breaker_cooldown_seconds: 3, tavily_credits_cooldown_seconds: 3,
      search_timeout_seconds: 1, budget_backoff_seconds: 600}
' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"

hdr() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
# ask name tenant product -> asks "What is the seat limit of Hooli <product>?" as the tenant's app
ask() {
  curl -s -m 30 -D "$LIB_TMP/$1.headers" -o "$LIB_TMP/$1.body" -X POST "$GW/v1/chat/completions" -H "x-bf-vk: sk-bf-halflife-$2" \
    -H 'content-type: application/json' -d "$(jq -cn --arg q "What is the seat limit of Hooli $3?" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')"
}
# report name -> waits for the report, leaves it in $LIB_TMP/name.json
report() {
  local id; id=$(hdr "$1" x-halflife-report)
  for _ in $(seq 1 150); do
    curl -s -m 5 -o "$LIB_TMP/$1.json" "$GW/api/halflife/reports/$id" -H "X-Bifrost-Setup-Token: $TOKEN"
    [ "$(jq -r .status "$LIB_TMP/$1.json")" = complete ] && return
    sleep 0.2
  done
  echo "report $1 ($id) did not complete" >&2; return 1
}
audit() { ask "$@"; report "$1"; }
r() { jq -c "$2" "$LIB_TMP/$1.json"; }
statuses() { curl -s "$TAVILY/_mock/requests" | jq -c --arg q "Hooli $1 seat limit" '[.search_log[] | select(.query == $q) | .status]'; }
llm_calls() { curl -s "$MOCK/_mock/requests" | jq .total; }
api() { curl -s -m 5 "$GW/api/halflife/$1" -H "X-Bifrost-Setup-Token: $TOKEN"; }
tavily() { api usage | jq -c ".dependencies.tavily | $1"; }

require_free_ports
start_mock
start_mock_tavily
start_gateway "$CONFIG" "$LOG"
check "startup log: audit mode" "$(grep -c '"halflife: initialized (mode=audit ' "$LOG")" 1
names=()

echo "--- 429 with a short Retry-After: waited out and retried"
audit notes acme Notes; names+=(notes)
check "searched twice (429, then 200); the claim is checked" "$(statuses Notes)/$(r notes '[.outcome, .claims[0].status]')" '[429,200]/["evidence_found","checked"]'
check "one failure, then a success: the circuit stays closed" "$(tavily '[.state, .consecutive_failures]')" '["closed",0]'

echo "--- 429 with a long Retry-After: the circuit opens instead of waiting"
audit drive acme Drive; names+=(drive)
check "one search, not retried; the claim failed as rate_limited" \
  "$(statuses Drive)/$(r drive '[.outcome, .claims[0].status, .claims[0].failure]')" '[429]/["search_failed","failed","rate_limited"]'
check "usage: the Tavily circuit is open, saying why" "$(tavily '[.state, .reason, .opens]')" '["open","rate limited, Retry-After 8s",1]'
llm=$(llm_calls)
audit mail acme Mail; names+=(mail)
check "while open, an audit makes no call: no extraction, no search (the 1 LLM call is the app's own answer)" \
  "$(r mail '[.outcome, .extraction, (.outcome_reason | test("tavily unavailable .*Retry-After 8s"))]')/$(statuses Mail)/$(( $(llm_calls) - llm ))" \
  '["verifier_unavailable",null,true]/[]/1'
check "metrics: halflife_circuit_open{dependency=\"tavily\"} 1" "$(api metrics | grep -c '^halflife_circuit_open{dependency="tavily"} 1$')" 1
sleep 8
audit chat acme Chat; names+=(chat)
check "after Retry-After, the probe succeeds and closes the circuit" "$(r chat '.claims[0].status')/$(tavily .state)" '"checked"/"closed"'

echo "--- 432: Tavily credits exhausted"
audit docs acme Docs; names+=(docs)
check "the claim is not checked, the audit says Tavily is unavailable" \
  "$(r docs '[.outcome, .claims[0].status, .claims[0].failure, (.claims[0].status_reason | startswith("Tavily credits exhausted"))]')" \
  '["verifier_unavailable","not_checked","out_of_credits",true]'
audit sheets acme Sheets; names+=(sheets)
check "the next audit makes no search, for the credits cooldown" \
  "$(statuses Sheets)/$(r sheets '[.outcome, (.outcome_reason | test("Tavily credits exhausted"))]')" '[]/["verifier_unavailable",true]'
sleep 3
audit slides acme Slides; names+=(slides)
check "after the cooldown, searches resume" "$(r slides '.claims[0].status')/$(tavily .state)" '"checked"/"closed"'

echo "--- 500 twice: consecutive failures open the circuit"
audit forms acme Forms; names+=(forms)
check "the 500 is retried once; both fail" "$(statuses Forms)/$(r forms '[.outcome, .claims[0].failure]')" '[500,500]/["search_failed","server_error"]'
check "2 consecutive failures (threshold 2): open" "$(tavily '[.state, (.reason | startswith("2 consecutive failures"))]')" '["open",true]'
audit keep acme Keep; names+=(keep)
check "while open: no search" "$(statuses Keep)/$(r keep .outcome)" '[]/"verifier_unavailable"'
sleep 3
audit tasks acme Tasks; names+=(tasks)
check "after the cooldown the probe closes it" "$(r tasks '.claims[0].status')/$(tavily '[.state, .opens]')" '"checked"/["closed",3]'

echo "--- a search slower than search_timeout_seconds"
start=$(date +%s)
audit meet acme Meet; names+=(meet)
check "times out (1 s): the claim failed as timeout, well before the mock's 2.5 s" \
  "$(r meet '[.outcome, .claims[0].failure]')/$(( $(date +%s) - start < 3 ))" '["search_failed","timeout"]/1'
check "one failure is under the threshold: still closed" "$(tavily '[.state, .consecutive_failures]')" '["closed",1]'

echo "--- Globex's verifier budget (1 credit) is spent"
audit voice globex Voice; names+=(voice)
check "Globex's search spends its credit; the Extract after it is refused (402)" \
  "$(r voice '[.outcome, .claims[0].evidence.credits, (.error | test("402")), .claims[0].status_reason]')" \
  '["evidence_found",1,true,"extract refused: verifier budget spent (402)"]'
llm=$(llm_calls) searches=$(curl -s "$TAVILY/_mock/requests" | jq .searches)
audit photos globex Photos; names+=(photos)
check "then Globex's audits pause with no verifier call (the 1 LLM call is the app's own answer)" \
  "$(r photos '[.outcome, .extraction, (.outcome_reason | test("paused until"))]')/$(( $(llm_calls) - llm ))/$(( $(curl -s "$TAVILY/_mock/requests" | jq .searches) - searches ))" \
  '["budget_exhausted",null,true]/1/0'
audit sheets2 acme Sheets; names+=(sheets2)
check "Acme is unaffected" "$(r sheets2 '[.outcome, .claims[0].status]')" '["evidence_found","checked"]'

echo "--- the same events in /metrics and /usage"
curl -s -m 5 -D "$LIB_TMP/metrics.headers" -o "$LIB_TMP/metrics.txt" "$GW/api/halflife/metrics" -H "X-Bifrost-Setup-Token: $TOKEN"
check "Prometheus text format" "$(hdr metrics content-type)" "text/plain; version=0.0.4; charset=utf-8"
m() { grep -c "^$1\$" "$LIB_TMP/metrics.txt" || true; }
check "circuit opens: Tavily 3, LLM 0" \
  "$(m 'halflife_circuit_opens_total{dependency="tavily"} 3')$(m 'halflife_circuit_opens_total{dependency="llm"} 0')" 11
check "Acme's failures by kind" \
  "$(for k in rate_limited out_of_credits server_error timeout; do m "halflife_failures_total{tenant=\"vk-acme\",kind=\"$k\"} 1"; done | paste -sd, -)" 1,1,1,1
check "Acme's audits by outcome: 5 found evidence, 3 failed, 4 unavailable" \
  "$(m 'halflife_audits_total{tenant="vk-acme",outcome="evidence_found"} 5')$(m 'halflife_audits_total{tenant="vk-acme",outcome="search_failed"} 3')$(m 'halflife_audits_total{tenant="vk-acme",outcome="verifier_unavailable"} 4')" 111
check "Globex: 1 credit, \$0.008, 1 audit paused by the budget" \
  "$(api usage | jq -c '.tenants[] | select(.tenant_virtual_key_id == "vk-globex") | [.tavily_credits, .tavily_usd, .outcomes.budget_exhausted, .verifier_virtual_key_id]')" \
  '[1,0.008,1,"vk-verifier-globex"]'
check "credits match mock Tavily's per-project count" \
  "$(api usage | jq -c '[.tenants[] | {(.tenant_virtual_key_id): .tavily_credits}] | add')" \
  "$(curl -s "$TAVILY/_mock/requests" | jq -c '.credits_by_project')"
check "no key value in the reports, the metrics or the gateway log" \
  "$(for n in "${names[@]}"; do cat "$LIB_TMP/$n.json"; done | cat - "$LIB_TMP/metrics.txt" "$LOG" | grep -cE 'tvly-[A-Za-z0-9]{8}|sk-bf-' || true)" 0

mkdir -p "$(dirname "$OUT")"
for n in "${names[@]}"; do
  jq -c --arg n "$n" '{name: $n, outcome, outcome_reason, error, claims: [.claims[] | {text, status, status_reason, failure, credits: .evidence.credits}]}' "$LIB_TMP/$n.json"
done | jq -s --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile usage <(api usage) \
  '{recorded_at: $at, mode: "mock", note: "Synthetic keys; mock LLM and mock Tavily with scripted faults.",
    reports: ., usage: ($usage[0] | {tenants: [.tenants[] | del(.audit_seconds)], dependencies: (.dependencies | map_values(del(.open_until)))})}' > "$OUT"
check "outcome record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
