#!/usr/bin/env bash
# Halflife's operational experiments (audit §6.5), measured through the real
# gateway on generated fixtures, so the ground truth is known: 20 widgets whose
# odd-numbered prices have changed since the mock model learned them.
#
#   fallback      the verifier's primary model goes down mid-run; audits move to
#                 the backup and finish
#   budget        a verifier budget below one run's cost: relay calls refused,
#                 claims NOT_CHECKED, user requests still 200. Then a spend cap,
#                 which stops the audits before the governance budget refuses
#   attribution   three apps on three keys; reports and credits per tenant
#                 match what was sent and what mock Tavily counted
#   cache         100 queries over 20 questions, Halflife monitoring vs acting:
#                 outdated answers served from the cache
#   expiry        a volatile answer leaves the cache at its band's TTL
#   recursion     verifier traffic never starts an audit
#
# What "cache" shows and doesn't: Halflife stops the cache multiplying an
# outdated answer, and flags each repeat. It does not correct the model, which
# gives the same answer when asked again. Mock LLM and mock Tavily only; no
# external call. Takes about two minutes. Writes testenv/results/experiments-mock.json.
set -Eeuo pipefail
trap 'echo "experiments.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
OUT="$ROOT/testenv/results/experiments-mock.json"
TOKEN=halflife-test-setup-token # synthetic, from the config
SETTLE=31                       # the shortest cache_write_settle_seconds allowed
EXPIRY=45                       # volatile band's TTL, past the settle window

question() { echo "What is the list price of Contoso Widget $1?"; }

jq -n '[range(1; 32)] | map({i: ., subject: "Contoso Widget \(.)", old: "$\(100 + .)", new: "$\(300 + .)",
    stale: (. <= 20 and . % 2 == 1)})
  | {replies: (map({key: "What is the list price of \(.subject)?", value: "\(.subject) lists at \(.old)."}) | from_entries),
     schema_replies: {
       atomic_claims: (map({key: "\(.subject) lists at \(.old).", value: ({claims: [{text: "\(.subject) lists at \(.old).", span: "\(.subject) lists at \(.old)",
           subject: .subject, attribute: "list price", asserted_value: .old, category: "price", temporal_scope: "CURRENT", as_of: "",
           volatility_band: (if .i == 21 then "HOURS_DAYS" else "WEEKS_MONTHS" end)}]} | tojson)}) | from_entries),
       claim_judgement: (map({key: "Claimed value: \(.old)\n", value: (
         (if .stale then {verdict: "CONTRADICTS", current_value: .new, quote: "\(.subject) lists at \(.new).", source: 1, once_true: true,
             history_quote: "Contoso raised \(.subject) from \(.old) to \(.new) in October 2026.", history_source: 2}
          else {verdict: "SUPPORTS", current_value: "", quote: "\(.subject) lists at \(.old).", source: 1, once_true: false,
             history_quote: "", history_source: 0} end) + {other_quote: "", other_source: 0} | tojson)}) | from_entries)}}' > "$LIB_TMP/llm.json"
jq -n '{search: ([range(1; 32)] | map({i: ., subject: "Contoso Widget \(.)", price: (if (. <= 20 and . % 2 == 1) then 300 + . else 100 + . end), old: (100 + .)})
  | map({key: "\(.subject | ascii_downcase) list price", value: [
      {title: "\(.subject) | Contoso", url: "https://contoso.example/widget-\(.i)", content: "\(.subject) lists at $\(.price).", score: 0.9, published_date: "2026-10-20"},
      {title: "Contoso price changes", url: "https://news.example/contoso-\(.i)", content: "Contoso raised \(.subject) from $\(.old) to $\(.price) in October 2026.", score: 0.8, published_date: "2026-10-20"}]}) | from_entries)}' > "$LIB_TMP/tavily.json"
export MOCK_LLM_FIXTURES="$LIB_TMP/llm.json" MOCK_TAVILY_FIXTURES="$LIB_TMP/tavily.json"

CONFIG="$LIB_TMP/experiments.json"
jq --slurpfile cache "$ROOT/testenv/configs/halflife-cache/config.json" '
  .vector_store = $cache[0].vector_store
  | .providers.openai.keys[0].models += ["primary", "backup", "mock-embed"]
  | (.governance.virtual_keys[] | select(.id | startswith("vk-verifier"))).provider_configs =
      [{provider: "openai", allowed_models: ["primary", "backup"], key_ids: ["*"], weight: 1.0}]
  | (.governance.budgets[] | select(.id == "budget-verifier-acme") | .max_limit) = 1
  | (.governance.budgets[] | select(.id == "budget-verifier-globex") | .max_limit) = 0.016
  | (.governance.budgets[] | select(.id == "budget-verifier-initech") | .max_limit) = 1
  | (.plugins[] | select(.name == "halflife") | .config) += {
      verifier_models: ["openai/primary", "openai/backup"], disable_extract: true, budget_backoff_seconds: 1,
      cache_write_settle_seconds: $settle, volatility_ttl_seconds: {HOURS_DAYS: $expiry}}
  | (.plugins[] | select(.name == "halflife") | .config.verifiers) += [{tenant: "vk-initech", virtual_key_id: "vk-verifier-initech",
      virtual_key: "sk-bf-halflife-verifier-initech", spend_cap_usd: 0.02}]
  | .plugins = [($cache[0].plugins[] | select(.name == "semantic_cache"))] + .plugins
  | (.governance.virtual_keys[] | select(.id | startswith("vk-verifier") | not)).provider_configs[0].allowed_models += ["mock-embed"]
' --argjson settle "$SETTLE" --argjson expiry "$EXPIRY" "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"

# ask tenant widget -> code|hit|status|report. Each widget has its own cache
# partition: an eviction's settle window holds its whole partition off the
# cache, and sharing one would make the count depend on audit timing.
ask() {
  local h="$LIB_TMP/ask.headers" b="$LIB_TMP/ask.body" code
  code=$(curl -s -m 30 -D "$h" -o "$b" -w '%{http_code}' -X POST "$GW/v1/chat/completions" -H "x-bf-vk: sk-bf-halflife-$1" \
    -H 'content-type: application/json' -H 'x-bf-cache-type: direct' -H "x-bf-cache-key: widget-$2" \
    -d "$(jq -cn --arg q "$(question "$2")" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')")
  echo "$code|$(jq -r '.extra_fields.cache_debug.cache_hit // false' "$b")|$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="x-halflife-status"{print $2}')|$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="x-halflife-report"{print $2}')"
}
api() { curl -s -m 5 "$GW/api/halflife/$1" -H "X-Bifrost-Setup-Token: $TOKEN"; }
# wait_reports id... -> waits until each report is complete
wait_reports() {
  for id in "$@"; do
    for _ in $(seq 1 150); do
      [ "$(api "reports/$id" | jq -r .status)" = complete ] && continue 2
      sleep 0.1
    done
    echo "report $id did not complete" >&2; return 1
  done
}
outcomes() { for id in "$@"; do api "reports/$id" | jq -r .outcome; done | sort | uniq -c | awk '{printf "%s%s=%s", s, $2, $1; s=","}'; }
calls() { curl -s "$MOCK/_mock/requests" | jq -r --arg m "$1" '.by_model[$m] // 0'; }
tenant() { api usage | jq -c --arg t "$1" ".tenants[] | select(.tenant_virtual_key_id == \$t) | $2"; }
codes() { sort -u | paste -sd, -; }

require_free_ports
ensure_redis
start_mock
start_mock_tavily
start_gateway "$CONFIG" "$ROOT/logs/experiments-gateway.log" "HalflifeExperiments_$(date +%s)"

echo "--- fallback: the primary verifier model goes down mid-run"
ids=(); seen=()
for w in 1 2 3 4; do IFS='|' read -r code _ _ id <<< "$(ask acme "$w")"; ids+=("$id"); seen+=("$code"); done
wait_reports "${ids[@]}"
before_primary=$(calls primary) before_backup=$(calls backup)
check "healthy: the primary does the work" "$(( before_primary >= 8 ))/$before_backup" 1/0
curl -s -X POST "$MOCK/_mock/outage" -d '{"model":"primary","status":503}'
down=()
for w in 5 6 7 8 9 10 11 12; do IFS='|' read -r code _ _ id <<< "$(ask acme "$w")"; down+=("$id"); seen+=("$code"); done
wait_reports "${down[@]}"
fallback_outcomes=$(outcomes "${down[@]}")
fallback_model=$(api "reports/${down[0]}" | jq -r .extraction.model)
check "every audit after the outage completed with evidence" "$fallback_outcomes" evidence_found=8
check "user requests were unaffected" "$(printf '%s\n' "${seen[@]}" | codes)" 200
check "the answers came from the backup" "$fallback_model" backup
fallback_backup=$(( $(calls backup) - before_backup ))
check "the backup took over extraction and judging" "$fallback_backup" 16
fallback_primary_tries=$(( $(calls primary) - before_primary ))
curl -s -X POST "$MOCK/_mock/outage" -d '{"model":"primary","status":0}'

echo "--- budget: a verifier budget below one run's cost"
ids=(); seen=()
for w in 1 2 3 4; do IFS='|' read -r code _ _ id <<< "$(ask globex "$w")"; ids+=("$id"); seen+=("$code"); done
wait_reports "${ids[@]}"
budget_outcomes=$(outcomes "${ids[@]}")
check "user requests stayed 200 while verification was refused" "$(printf '%s\n' "${seen[@]}" | codes)" 200
check "the budget paid for two searches (\$0.016 at \$0.008) and refused the rest" "$(tenant vk-globex '.tavily_credits')" 2
check "the rest are budget_exhausted, not failures" "$(( $(api reports?tenant=vk-globex | jq '[.reports[] | select(.outcome == "budget_exhausted")] | length') >= 1 ))" 1

echo "--- spend cap: Initech's \$0.02 stops the audits, not a refused relay call"
ids=(); seen=()
for w in 1 2 3 4; do IFS='|' read -r code _ _ id <<< "$(ask initech "$w")"; ids+=("$id"); seen+=("$code"); wait_reports "$id"; done
cap_outcomes=$(outcomes "${ids[@]}")
check "two claims are checked, two audits stop at the cap" "$cap_outcomes" budget_exhausted=2,evidence_found=2
check "no refused calls: the cap came first" "$(api "reports/${ids[3]}" | jq -c '[(.error // ""), (.outcome_reason | startswith("spend cap reached"))]')" '["",true]'
check "usage shows the window" "$(api usage | jq -c '.spend["vk-initech"] | [.cap_usd, (.spent_usd * 1000 | round), (.resets_at != null)]')" '[0.02,16,true]'
check "user requests stayed 200" "$(printf '%s\n' "${seen[@]}" | codes)" 200

echo "--- attribution: three apps on three keys"
reports_by_tenant=$(api 'reports?limit=100' | jq -cS '[.reports[].tenant_virtual_key_id] | group_by(.) | map({(.[0]): length}) | add')
check "reports match the requests each app sent" "$reports_by_tenant" '{"vk-acme":12,"vk-globex":4,"vk-initech":4}'
check "credits per tenant match mock Tavily's per-project count" \
  "$(api usage | jq -cS '[.tenants[] | {(.tenant_virtual_key_id): .tavily_credits}] | add')" \
  "$(curl -s "$TAVILY/_mock/requests" | jq -cS '.credits_by_project')"
attribution=$(api usage | jq -c '[.tenants[] | {tenant: .tenant_virtual_key_id, audits, tavily_credits, tavily_usd, verifier: .verifier_virtual_key_id}]')

echo "--- recursion: verifier traffic starts no audit"
total_llm=$(curl -s "$MOCK/_mock/requests" | jq .total)
captured=$(api usage | jq .requests.Captured)
check "20 app requests were captured, out of $total_llm LLM calls" "$captured" 20
check "no report belongs to a verifier key" "$(api 'reports?limit=100' | jq '[.reports[] | select(.tenant_virtual_key_id | startswith("vk-verifier"))] | length')" 0
stop_gateway

# cache_run mode -> sets $result to the 100 queries' counts, as JSON. Monitor
# adds no response headers, so audits are waited for through /usage.
cache_run() {
  local mode="$1" stale=0 from_cache=0 flagged=0 fresh=0 regenerated=0 w
  jq --arg mode "$mode" '(.plugins[] | select(.name == "halflife") | .config.mode) = $mode' "$CONFIG" > "$LIB_TMP/cache-$mode.json"
  start_gateway "$LIB_TMP/cache-$mode.json" "$ROOT/logs/experiments-$mode-gateway.log" "HalflifeExperiments_${mode}_$(date +%s)"
  for w in $(seq 1 20); do ask acme "$w" >/dev/null; done
  for _ in $(seq 1 150); do [ "$(tenant vk-acme .audits)" = 20 ] && break; sleep 0.1; done
  check "$mode: all 20 first answers audited" "$(tenant vk-acme .audits)" 20
  sleep $(( SETTLE + 1 )) # the eviction's write-race window, for the rounds to measure the settled state
  for round in 1 2 3 4; do
    for w in $(seq 1 20); do
      IFS='|' read -r _ hit status _ <<< "$(ask acme "$w")"
      if (( w % 2 == 1 )); then
        stale=$((stale+1))
        [ "$hit" = true ] && from_cache=$((from_cache+1))
        [ "$hit" = true ] || regenerated=$((regenerated+1))
        [ "$status" = known-outdated ] && flagged=$((flagged+1))
      else
        [ "$hit" = true ] && fresh=$((fresh+1))
      fi
    done
  done
  result=$(jq -cn --arg mode "$mode" --argjson stale "$stale" --argjson from_cache "$from_cache" --argjson regenerated "$regenerated" --argjson flagged "$flagged" --argjson fresh "$fresh" \
    --argjson requests "$(api usage | jq -c .requests)" \
    '{mode: $mode, outdated_requests: $stale, outdated_served_from_cache: $from_cache, outdated_regenerated: $regenerated, flagged_known_outdated: $flagged,
      current_served_from_cache: $fresh, evictions: $requests.Invalidated, tombstone_bypasses: $requests.TombstoneBypasses, tombstone_reuses: $requests.TombstoneReuses}')
}

echo "--- cache: 100 queries over 20 questions, 10 of them outdated"
cache_run monitor; monitor=$result; stop_gateway
echo "monitor: $monitor"
check "monitor: every repeat of an outdated answer comes from the cache" "$(jq -c '[.outdated_served_from_cache, .evictions]' <<< "$monitor")" '[40,0]'
cache_run audit; audit=$result
echo "audit:   $audit"
check "audit: none does, and each repeat is flagged without another audit" \
  "$(jq -c '[.outdated_served_from_cache, .flagged_known_outdated, .evictions, .tombstone_reuses]' <<< "$audit")" '[0,40,10,40]'
check "current answers keep their hits" "$(jq .current_served_from_cache <<< "$audit")" 40

echo "--- expiry: a volatile answer leaves the cache at its band's TTL"
IFS='|' read -r _ _ _ id <<< "$(ask acme 21)"
wait_reports "$id"
sleep 1
IFS='|' read -r _ hit _ _ <<< "$(ask acme 21)"
check "hit before the TTL" "$hit" true
sleep $(( EXPIRY + 1 ))
IFS='|' read -r _ hit _ _ <<< "$(ask acme 21)"
check "evicted after it, by the volatility expiry" "$hit/$(api metrics | grep -c '^halflife_cache_expiries_total 1$')" false/1

mkdir -p "$(dirname "$OUT")"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson monitor "$monitor" --argjson audit "$audit" --argjson attribution "$attribution" --argjson recursion "{\"captured\":$captured,\"llm_calls\":$total_llm}" \
  --arg fallback "$fallback_outcomes" --arg budget "$budget_outcomes" --arg cap "$cap_outcomes" --argjson backup "$fallback_backup" --argjson tries "$fallback_primary_tries" \
  '{recorded_at: $at, mode: "mock", note: "Synthetic keys; mock LLM and mock Tavily on generated fixtures, so the outdated answers are known by construction. The rates show the mechanism, not real-world detection accuracy.",
    fallback: {audits_after_outage: $fallback, backup_calls: $backup, primary_attempts_during_outage: $tries}, budget: {outcomes: $budget}, spend_cap: {outcomes: $cap}, attribution: $attribution,
    cache: {monitor: $monitor, audit: $audit, note: "Audit stops the cache serving outdated answers; the model still gives them, flagged known-outdated."}, recursion: $recursion}' > "$OUT"
check "the record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
