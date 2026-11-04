#!/usr/bin/env bash
# Claim pipeline through the real gateway: a tenant's answer is captured, the
# verifier LLM splits it into atomic claims (structured output, Acme's
# verifier key), the span check rejects drifted claims, temporal scope and
# priority skip what cannot go stale, each remaining claim is searched on
# Tavily through the relay with its category's retrieval policy, and the judge
# (structured output again) reads the evidence; typed comparators and verbatim
# quote checks decide the verdict, then strength and score follow. Config
# testenv/configs/m1 with an overlay.
#
#   default   mock LLM (answers, extraction, judge) and mock Tavily; no
#             external call. Reports go to a SQLite store, and the gateway is
#             restarted to show they survive, with the answer text redacted.
#   LIVE=1    the answer still comes from the mock (a fixed text); extraction
#             and the judge run on free OpenRouter models, searches on real
#             Tavily.
#             Spend is capped by max_claims_per_response=3 and Acme's verifier
#             budget ($0.04, 5 credits). Needs OPENROUTER_API_KEY and
#             TAVILY_API_KEY in .env; the script never reads either.
#
# Writes testenv/results/claims-{mock,live}.json: each report's claims, their
# scope, priority, search parameters and source URLs. No page text, no key.
set -Eeuo pipefail
trap 'echo "claims-pipeline.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LIVE="${LIVE:-}"
MODE=$([ -n "$LIVE" ] && echo live || echo mock)
LOG="$ROOT/logs/claims-pipeline-$MODE-gateway.log"
OUT="$ROOT/testenv/results/claims-$MODE.json"
TOKEN=halflife-test-setup-token # synthetic, from the config
APP_VK=sk-bf-halflife-acme      # synthetic
# Free on OpenRouter with structured outputs (listed 3 Nov 2026), as in
# verifier-llm.sh; the first is asked, the rest are Bifrost fallbacks.
LIVE_MODELS="nvidia/nemotron-3.5-super-vl:free xingchen-agi/xing4.0-29b-a4b:free openrouter/free"

CONFIG="$LIB_TMP/claims.json"
if [ -n "$LIVE" ]; then
  for k in OPENROUTER_API_KEY TAVILY_API_KEY; do
    grep -q "^$k=." "$ROOT/.env" 2>/dev/null || { echo "$k is not set in .env" >&2; exit 1; }
  done
  MODELS=$(for m in $LIVE_MODELS; do printf 'openrouter/%s,' "$m"; done | sed 's/,$//')
  jq --arg ms "$LIVE_MODELS" --arg models "$MODELS" '
    .providers.openrouter = {keys: [{name: "openrouter", value: "env.OPENROUTER_API_KEY", models: ($ms | split(" ")), weight: 1.0}],
                             network_config: {default_request_timeout_in_seconds: 90, max_retries: 1}}
    | (.governance.virtual_keys[] | select(.id == "vk-verifier-acme") | .provider_configs)
        += [{provider: "openrouter", allowed_models: ($ms | split(" ")), key_ids: ["*"], weight: 1.0}]
    | (.governance.budgets[] | select(.id == "budget-verifier-acme") | .max_limit) = 0.04
    | (.relays[] | select(.name == "tavily")) |= (.base_url = "https://api.tavily.com" | .credential.value = "env.TAVILY_API_KEY")
    | (.plugins[] | select(.name == "halflife") | .config) += {verifier_models: ($models | split(",")), verifier_reasoning_effort: "low",
        verifier_max_tokens: 4096, max_claims_per_response: 3, audit_timeout_seconds: 170, preferred_domains: {version: ["go.dev"]}}
  ' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"
else
  MODELS=openai/ok
  STORE="$LIB_TMP/reports.db"
  jq --arg models "$MODELS" --arg store "$STORE" '
    (.governance.budgets[] | select(.id == "budget-verifier-acme") | .max_limit) = 1
    | (.plugins[] | select(.name == "halflife") | .config) += {verifier_models: ($models | split(",")),
        preferred_domains: {version: ["code.example"]}, report_store_path: $store}
  ' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"
fi

hdr() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
# ask name question -> $LIB_TMP/name.{headers,body}; Acme's app key, the mock's answer
ask() {
  curl -s -m 60 -D "$LIB_TMP/$1.headers" -o "$LIB_TMP/$1.body" -X POST "$GW/v1/chat/completions" -H "x-bf-vk: $APP_VK" \
    -H 'content-type: application/json' -d "$(jq -cn --arg q "$2" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')"
  echo "$1: report=$(hdr "$1" x-halflife-report) status=$(hdr "$1" x-halflife-status)"
}
# report name -> $LIB_TMP/name.json once complete (up to 180 s: free models are slow)
report() {
  local id status=none; id=$(hdr "$1" x-halflife-report)
  [ -n "$id" ] || { echo none; return; }
  for _ in $(seq 1 900); do
    status=$(curl -s -m 5 -o "$LIB_TMP/$1.json" -w '%{http_code}' "$GW/api/halflife/reports/$id" -H "X-Bifrost-Setup-Token: $TOKEN")
    [ "$status" != 200 ] && break
    [ "$(jq -r .status "$LIB_TMP/$1.json")" = complete ] && break
    sleep 0.2
  done
  echo "$status"
}
r() { jq -c "$2" "$LIB_TMP/$1.json"; }
searchlog() { curl -s "$TAVILY/_mock/requests" | jq -c "$1"; }
captured() { grep -c '"halflife: captured ' "$LOG" || true; }

require_free_ports
start_mock # answers every tenant question, in both modes
[ -z "$LIVE" ] && start_mock_tavily
start_gateway "$CONFIG" "$LOG"
echo "mode: $MODE"
check "startup log: one verifier model chain configured" \
  "$(grep -c "\"halflife: initialized (.*verifier_models=$(echo "$MODELS" | tr ',' '\n' | wc -l | tr -d ' ') " "$LOG")" 1
before=$(captured)
names=()

if [ -z "$LIVE" ]; then
  echo "--- an answer with five extracted claims"
  ask overview "Give me an overview of Acme Cloud."; names+=(overview)
  check "report complete: evidence found" "$(report overview)/$(r overview '[.status, .outcome]')" '200/["complete","evidence_found"]'
  check "extraction ran once on the verifier model; the judge came last, strict schema" \
    "$(r overview '[.extraction.model, .extraction.calls]')/$(curl -s "$MOCK/_mock/requests" | jq -r .last_response_format)" '["ok",1]/json_schema:claim_judgement:strict'
  check "statuses: price, storage, version checked; founding skipped; drifted price rejected" \
    "$(r overview '[.claims[].status]')" '["checked","checked","not_checked","checked","rejected"]'
  check "the founding claim: historical (dated), SKIP" \
    "$(r overview '.claims[2] | [.temporal_scope, .scope_reason, .priority, (.status_reason | startswith("priority SKIP: historical"))]')" \
    '["HISTORICAL","tied to a past date (as_of)","SKIP",true]'
  check "the drifted claim never searched: value not in the span" "$(r overview '.claims[4] | [.status_reason, .search]')" '["asserted value is not in the span",null]'
  check "current claims are HIGH: 18-month default cutoff age (no as_of, no cutoff configured)" \
    "$(r overview '[.claims[0,1] | .priority_reason | test("since default 18-month cutoff age")] + [.claims[3].priority_reason]')" '[true,true,"says latest/current/now"]'
  check "price search: subject and attribute only, weeks band max_age 24, 3 chunks, dates, Acme as the project" \
    "$(searchlog '[.search_log[] | select(.query == "Acme Cloud Pro monthly price") | [.max_age_hours, .chunks_per_source, .include_published_date, .topic, .x_project_id]]')" \
    '[[24,3,true,null,"vk-acme"]]'
  check "version search: quoted subject, exact match, preferred domain" \
    "$(searchlog '[.search_log[] | select(.exact_match) | [.query, .include_domains, .include_domains_mode]]')" '[["\"Acme SDK\" latest version",["code.example"],"prefer"]]'
  check "version evidence from the preferred domain" "$(r overview '.claims[3].evidence.sources[0].url')" '"https://code.example/acme/acme-sdk/releases"'
  check "no query carries an asserted value" "$(searchlog '[.search_log[].query | select(test("\\$20|3\\.2\\.0|100 GB"))] | length')" 0
  check "storage snippets had no figure: one Extract of the top page, with the claim as query" \
    "$(searchlog '[.extract_log[] | [.query, .x_project_id]]')/$(r overview '.claims[1].evidence | [(.extracted_url | startswith("https://example.com/a/")), (.sources[0].extracted | length > 0)]')" \
    '[["Acme Cloud Pro included storage","vk-acme"]]/[true,true]'
  check "price evidence was not thin: no Extract" "$(r overview '.claims[0].evidence.extracted_url')" null
  check "verdicts: price OUTDATED, storage UNVERIFIABLE, founding and drifted NOT_CHECKED, version CONTRADICTED; report OUTDATED" \
    "$(r overview '[[.claims[].verdict], .verdict]')" '[["OUTDATED","UNVERIFIABLE","NOT_CHECKED","CONTRADICTED","NOT_CHECKED"],"OUTDATED"]'
  check "price OUTDATED: comparator differs, quote and history quote verified, two domains with a primary (STRONG, 5)" \
    "$(r overview '.claims[0] | [.comparison.kind, .comparison.result, .quote.verified, .quote.url, .history_quote.verified, .history_quote.url, .strength, .freshness_score]')" \
    '["price","different",true,"https://acme.example/pricing",true,"https://news.example/acme-pro-price","STRONG",5]'
  check "version CONTRADICTED: no history quote, one preferred domain (MODERATE, 15)" \
    "$(r overview '.claims[3] | [.observed_value, .comparison.result, .history_quote, .strength, .freshness_score]')" '["4.1.0","different",null,"MODERATE",15]'
  check "storage: the judge found the evidence silent; no strength or score" \
    "$(r overview '.claims[1] | [.verdict_reason, .strength, .freshness_score]')" '["the evidence does not say",null,null]'
  check "unjudged claims say why" "$(r overview '[.claims[2,4].verdict_reason | split(":")[0]]')" '["priority SKIP","rejected by the span check"]'

  echo "--- live fetch refused, and a leadership claim"
  ask today "How is Acme doing today?"; names+=(today)
  check "report complete: evidence found" "$(report today)/$(r today .outcome)" '200/"evidence_found"'
  check "share price (hours band): max_age 0 refused with 434, retried without it" \
    "$(searchlog '[.search_log[] | select(.query == "Acme stock share price") | [.status, .max_age_hours]]')/$(r today '.claims[0].evidence | [.live_fetch_refused, .credits, (.sources | length)]')" \
    '[[434,0],[200,null]]/[true,1,1]'
  check "CEO: news, this year, no max_age (years band)" \
    "$(searchlog '[.search_log[] | select(.query == "Acme Cloud CEO") | [.topic, .time_range, .max_age_hours]]')" '[["news","year",null]]'
  check "share price CONTRADICTED on one non-primary domain (WEAK, 30)" \
    "$(r today '.claims[0] | [.verdict, .observed_value, .strength, .freshness_score]')" '["CONTRADICTED","$131.40","WEAK",30]'
  check "CEO: the judge said SUPPORTS, the name comparator overruled it (CONTRADICTED, MODERATE, 15)" \
    "$(r today '.claims[1] | [.verdict, .comparison.kind, .comparison.result, (.verdict_reason | test("overrode the judge.s SUPPORTS")), .strength, .freshness_score]')" \
    '["CONTRADICTED","name","different",true,"MODERATE",15]'

  echo "--- only settled history"
  searches=$(searchlog .searches)
  ask history "When was Acme Cloud started?"; names+=(history)
  check "nothing to check: no search" "$(report history)/$(r history '[.outcome, .claims[0].priority]')/$(searchlog .searches)" "200/[\"nothing_to_check\",\"SKIP\"]/$searches"
  check "Tavily credits: price, storage, version, share price, CEO (the 434 cost none)" "$(searchlog .credits_by_project.\"vk-acme\")" 5
else
  echo "--- a fixed answer, real extraction and real Tavily"
  ask live "Give me an overview of Go and GitHub Copilot."; names+=(live)
  check "report complete" "$(report live)/$(r live .status)" '200/"complete"'
  echo "outcome: $(r live .outcome)  error: $(r live '.error // "-"')"
  echo "extraction: $(r live '.extraction | {model, fallback, calls, malformed, truncated}')"
  echo "claims:"
  r live '.claims[] | {text, category, temporal_scope, volatility_band, priority, status, status_reason, query: .search.query, max_age: .search.max_age_hours, credits: .evidence.credits, top: .evidence.sources[0].url}' | sed 's/^/  /'
  check "the audit finished: no error, no failed search, no judge failure" \
    "$(r live '[.error, ([.claims[] | select(.status == "failed" or (.verdict_reason // "" | startswith("judge failed")))] | length)]')" '[null,0]'
  check "extraction returned schema-valid claims" "$(r live '(.claims | length) > 0')" true
  check "every claim passed the span check or was rejected with a reason" \
    "$(r live '[.claims[] | select(.status == "rejected") | .status_reason != null] | all')" true
  check "at most 3 claims searched (max_claims_per_response)" "$(r live '[.claims[] | select(.search != null)] | length <= 3')" true
  check "every search kept the asserted value out of its query" \
    "$(r live '[.claims[] | . as $c | select(.search != null and (.asserted_value // "") != "") | .search.query | contains($c.asserted_value) | not] | all')" true
  check "at least one claim checked with sources" "$(r live '[.claims[] | select(.status == "checked" and (.evidence.sources | length) > 0)] | length > 0')" true
  echo "verdicts: $(r live '.verdict')"
  r live '.claims[] | {verdict, verdict_reason, observed_value, comparison: (.comparison | if . == null then null else "\(.kind) \(.result)" end), quote_verified: .quote.verified, quote_url: .quote.url, strength, freshness_score, judge: .judge.model}' | sed 's/^/  /'
  check "every claim has a verdict with a reason" "$(r live '[.claims[] | .verdict != null and .verdict_reason != null] | all')" true
  check "no CURRENT, OUTDATED or CONTRADICTED verdict without a verified quote" \
    "$(r live '[.claims[] | select(.verdict | IN("CURRENT","OUTDATED","CONTRADICTED")) | .quote.verified] | all')" true
  check "no OUTDATED verdict without a verified history quote" \
    "$(r live '[.claims[] | select(.verdict == "OUTDATED") | .history_quote.verified] | all')" true
  check "scores only where the table defines one" \
    "$(r live '[.claims[] | (.freshness_score != null) == (.verdict | IN("CURRENT","OUTDATED","CONTRADICTED","CONFLICTING"))] | all')" true
fi

check "the verifier's own calls were never captured for audit" "$(( $(captured) - before ))" "${#names[@]}"

ids=$(for n in "${names[@]}"; do r "$n" '.extraction.gateway_request_ids[]?, .claims[].judge.gateway_request_ids[]?' | tr -d '"'; done | sort -u)
judged=$(for n in "${names[@]}"; do r "$n" '.claims[] | select(.judge != null) | .text'; done | wc -l | tr -d ' ')
stop_gateway # flushes the request log
rows=$(for id in $ids; do sqlite3 -separator ' ' "$GATEWAY_APP/logs.db" "select virtual_key_id, customer_id from logs where id = '$id'"; done | sort -u | paste -sd, -)
found=$(for id in $ids; do sqlite3 "$GATEWAY_APP/logs.db" "select count(*) from logs where id = '$id'"; done | paste -sd+ - | bc)
check "every extraction and judge call ($(echo "$ids" | wc -l | tr -d ' ') for $judged judged claims) is in Bifrost's request log on Acme's verifier key and customer" \
  "$rows/$found" "vk-verifier-acme cust-acme/$(echo "$ids" | wc -l | tr -d ' ')"

if [ -z "$LIVE" ]; then
  echo "--- the reports survive a restart"
  start_gateway "$CONFIG" "${LOG%.log}-restart.log"
  id=$(hdr overview x-halflife-report)
  curl -s -m 5 -o "$LIB_TMP/persisted.json" "$GW/api/halflife/reports/$id" -H "X-Bifrost-Setup-Token: $TOKEN"
  check "served from SQLite after the restart: same claims, verdicts and scores" \
    "$(jq -c '[.claims[] | [.verdict, .strength, .freshness_score]]' "$LIB_TMP/persisted.json")" "$(r overview '[.claims[] | [.verdict, .strength, .freshness_score]]')"
  check "the answer text is not persisted by default; the claims are" \
    "$(jq -c '[.answer.text_redacted, .answer.text, .answer.question, (.claims | length)]' "$LIB_TMP/persisted.json")" '[true,"",null,5]'
  stop_gateway
  check "provenance rows: claims by verdict, with the verifier key and the relay call" \
    "$(sqlite3 -separator ' ' "$STORE" "select verdict, count(*), min(verifier_virtual_key_id) from claims where status = 'checked' group by verdict order by verdict" | paste -sd, -)" \
    "CONTRADICTED 3 vk-verifier-acme,OUTDATED 1 vk-verifier-acme,UNVERIFIABLE 1 vk-verifier-acme"
  check "every judged claim names its judge calls; every searched claim its relay request" \
    "$(sqlite3 "$STORE" "select count(*) from claims where status = 'checked' and (judge_request_ids = '[]' or relay_request_id = '')")" 0
  check "source rows by registrable domain" \
    "$(sqlite3 "$STORE" "select distinct domain from claim_sources order by domain" | paste -sd, -)" \
    "acme.example,code.example,example.com,example.org,markets.example,news.example"
  check "the answer text is in no stored row" "$(sqlite3 "$STORE" "select count(*) from reports where document like '%Acme Cloud Pro costs \$20 per month and includes%'")" 0
fi
check "no key value in the reports or the gateway log" \
  "$(for n in "${names[@]}"; do cat "$LIB_TMP/$n.json"; done | cat - "$LOG" | grep -cE 'sk-or-|tvly-[A-Za-z0-9]{8}|sk-bf-' || true)" 0

mkdir -p "$(dirname "$OUT")"
for n in "${names[@]}"; do
  jq -c --arg n "$n" '{name: $n, outcome, verdict, error, extraction: (.extraction | if . == null then null else {model, provider, fallback, calls, malformed, truncated} end),
    claims: [.claims[] | {text, span, subject, attribute, asserted_value, category, temporal_scope, scope_reason, as_of, volatility_band,
      priority, priority_reason, status, status_reason, search, verdict, verdict_reason, observed_value, comparison,
      quote: (.quote | if . == null then null else {source, url, verified} end), history_verified: .history_quote.verified,
      judge: (.judge | if . == null then null else {model, fallback, calls, malformed, truncated} end), strength, strength_reason, freshness_score,
      evidence: (.evidence | if . == null then null else {credits, reused, live_fetch_refused, extracted_url,
        sources: [.sources[] | {url, title, published_date, extracted: ((.extracted // "") != "")}]} end)}]}' "$LIB_TMP/$n.json"
done | jq -s --arg mode "$MODE" --arg models "$MODELS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{recorded_at: $at, mode: $mode, verifier_models: ($models | split(",")), note: "Synthetic keys; no credential and no page text recorded.", reports: .}' > "$OUT"
check "outcome record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
