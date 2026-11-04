#!/usr/bin/env bash
# What an operator sees, through the real gateway. Mock LLM and mock Tavily
# only; no external call.
#
#   protect   X-Halflife-Protect: true waits for the verdict and returns it in
#             X-Halflife-Verdict; past protect_timeout_ms the response goes out
#             without one and the audit still completes (fail-open)
#   evidence  a snippet tells the model to answer SUPPORTS and the scripted
#             judge obeys: the instruction is removed, the source flagged, the
#             verdict refused; two unsafe URLs never reach the report
#   list      GET /api/halflife/reports filters, pages, and needs dashboard auth
#   usage     GET /api/halflife/usage and /metrics agree with the reports
#   monitor   responses carry nothing from Halflife (same headers as with the
#             plugin off), and the report is found by request ID
#
# Writes testenv/results/operator-mock.json.
set -Eeuo pipefail
trap 'echo "operator.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LOG="$ROOT/logs/operator-gateway.log"
OUT="$ROOT/testenv/results/operator-mock.json"
TOKEN=halflife-test-setup-token # synthetic, from the config

overlay() { # overlay OUTPUT JQ-EXPRESSION-FOR-THE-HALFLIFE-PLUGIN
  jq "(.governance.budgets[] | select(.id == \"budget-verifier-acme\") | .max_limit) = 1
    | (.plugins[] | select(.name == \"halflife\")) |= ($2)" "$ROOT/testenv/configs/m1/config.json" > "$1"
}
overlay "$LIB_TMP/protect.json" '.config += {verifier_models: ["openai/ok"], mode: "protect", protect_timeout_ms: 500}'
overlay "$LIB_TMP/monitor.json" '.config += {verifier_models: ["openai/ok"], mode: "monitor"}'
overlay "$LIB_TMP/off.json" '.enabled = false'

hdr() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }
# ask name product [curl args] -> $LIB_TMP/name.{headers,body}, as Acme's app
ask() {
  local name=$1 product=$2; shift 2
  curl -s -m 30 -D "$LIB_TMP/$name.headers" -o "$LIB_TMP/$name.body" -X POST "$GW/v1/chat/completions" -H 'x-bf-vk: sk-bf-halflife-acme' "$@" \
    -H 'content-type: application/json' -d "$(jq -cn --arg q "What is the seat limit of Hooli $product?" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')"
}
api() { curl -s -m 5 "$GW/api/halflife/$1" -H "X-Bifrost-Setup-Token: $TOKEN"; }
# report name id -> waits for the report, leaves it in $LIB_TMP/name.json
report() {
  for _ in $(seq 1 150); do
    api "reports/$2" > "$LIB_TMP/$1.json"
    [ "$(jq -r .status "$LIB_TMP/$1.json")" = complete ] && return
    sleep 0.2
  done
  echo "report $1 ($2) did not complete" >&2; return 1
}
r() { jq -c "$2" "$LIB_TMP/$1.json"; }
answer() { jq -r '.choices[0].message.content' "$LIB_TMP/$1.body"; }
halflife_headers() { tr -d '\r' < "$LIB_TMP/$1.headers" | grep -ci 'halflife' || true; }
header_names() { tr -d '\r' < "$LIB_TMP/$1.headers" | awk -F': ' 'NF>1{print tolower($1)}' | sort | paste -sd, -; }

require_free_ports
start_mock
start_mock_tavily

echo "=== protect mode"
start_gateway "$LIB_TMP/protect.json" "$LOG"
check "startup log: protect mode" "$(grep -c '"halflife: initialized (mode=protect ' "$LOG")" 1

echo "--- a protected request gets its verdict, and the body is untouched"
ask wave Wave -H 'X-Halflife-Protect: true'
id=$(hdr wave x-halflife-report)
report wave "$id"
check "verified, with the report's verdict in the header" \
  "$(hdr wave x-halflife-status)/$(hdr wave x-halflife-verdict)" "verified/$(r wave .verdict | tr -d '"')"
check "the verdict header is exposed to browsers" "$(hdr wave access-control-expose-headers | grep -c x-halflife-verdict)" 1
check "the answer is returned as the model wrote it" "$(answer wave)" "Hooli Wave has a limit of 60 seats."

echo "--- instructions in the evidence are data"
check "the injected source is kept, flagged, with the instruction removed" \
  "$(r wave '.claims[0].evidence.sources[1] | [.url, .flagged, .flag_reason, (.snippet | test("Ignore all previous")), (.snippet | test("\\[removed\\]"))]')" \
  '["https://forum.example/hooli-wave",true,"asks to ignore instructions",false,true]'
check "the judge said SUPPORTS on the flagged source: refused" \
  "$(r wave '.claims[0] | [.verdict, .verdict_reason, .quote.flagged]')" \
  '["UNVERIFIABLE","the quote comes from a source flagged for instruction-like text",true]'
check "javascript: and credentialed URLs dropped and counted" \
  "$(r wave '.claims[0].evidence | [.dropped_sources, ([.sources[].url] | any(test("javascript|hunter2")))]')" '[2,false]'
check "the credential in the dropped URL is nowhere in the gateway log" "$(grep -c hunter2 "$LOG" || true)" 0

echo "--- an unprotected request does not wait"
ask chat Chat
check "queued, no verdict" "$(hdr chat x-halflife-status)/$(hdr chat x-halflife-verdict)" queued/
report chat "$(hdr chat x-halflife-report)"

echo "--- slower than protect_timeout_ms: fail-open"
start=$(python3 -c 'import time; print(int(time.time()*1000))')
ask pages Pages -H 'X-Halflife-Protect: true'
took=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - start ))
check "sent at the timeout, without a verdict, with the answer" \
  "$(hdr pages x-halflife-status)/$(hdr pages x-halflife-verdict)/$(answer pages)/$(( took >= 500 && took < 1400 ))" \
  "verify-timeout//Hooli Pages has a limit of 50 seats./1"
report pages "$(hdr pages x-halflife-report)"
check "the audit carries on and completes the report" "$(r pages '[.status, .outcome]')" '["complete","evidence_found"]'

echo "--- the report list"
ids() { jq -c '[.reports[].id]' <<<"$1"; }
check "newest first" "$(ids "$(api 'reports?tenant=vk-acme')")" \
  "$(jq -cn --arg a "$(hdr pages x-halflife-report)" --arg b "$(hdr chat x-halflife-report)" --arg c "$(hdr wave x-halflife-report)" '[$a,$b,$c]')"
page=$(api 'reports?tenant=vk-acme&limit=2')
check "a full page says where the next one starts" "$(jq -r .next_before <<<"$page")" "$(hdr chat x-halflife-report)"
check "the next page" "$(ids "$(api "reports?tenant=vk-acme&limit=2&before=$(jq -r .next_before <<<"$page")")")" "[\"$(hdr wave x-halflife-report)\"]"
check "by request ID" "$(api "reports?request_id=$(r wave .request_id | tr -d '"')" | jq -c '[.reports[] | [.id, .verdict, .provider, .model]]')" \
  "[[\"$(hdr wave x-halflife-report)\",\"UNVERIFIABLE\",\"openai\",\"ok\"]]"
check "by model, and no match for another tenant" \
  "$(api 'reports?model=ok' | jq '.reports | length')/$(api 'reports?tenant=vk-globex' | jq -c .reports)" '3/[]'
check "a bad limit is refused" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/reports?limit=0" -H "X-Bifrost-Setup-Token: $TOKEN")" 400
for route in reports usage metrics; do
  check "/api/halflife/$route without the token is refused" "$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/halflife/$route")" 401
done

echo "--- usage and metrics"
api usage > "$LIB_TMP/usage.json"
check "usage: mode, one tenant, three audits, three credits, none failed" \
  "$(jq -c '[.mode, (.tenants | length), .tenants[0].audits, .tenants[0].tavily_credits, .tenants[0].failures]' "$LIB_TMP/usage.json")" '["protect",1,3,3,{}]'
check "usage: protected requests by result" "$(jq -c '.requests | [.ProtectVerified, .ProtectTimeouts]' "$LIB_TMP/usage.json")" '[1,1]'
check "usage: the flagged answer counted" "$(jq -c '.tenants[0].verdicts.UNVERIFIABLE' "$LIB_TMP/usage.json")" 3
check "metrics: the same credits" "$(api metrics | grep -c '^halflife_tavily_credits_total{tenant="vk-acme"} 3$')" 1
check "credits match mock Tavily" "$(curl -s "$TAVILY/_mock/requests" | jq '.credits_by_project."vk-acme"')" 3
stop_gateway

echo "=== monitor mode"
start_gateway "$LIB_TMP/off.json" "${LOG%.log}-off.log"
ask plain Tasks
stop_gateway
start_gateway "$LIB_TMP/monitor.json" "${LOG%.log}-monitor.log"
check "startup log: monitor mode" "$(grep -c '"halflife: initialized (mode=monitor ' "${LOG%.log}-monitor.log")" 1
ask quiet Tasks -H 'X-Halflife-Protect: true'
check "nothing from Halflife in the response, even when asked" "$(halflife_headers quiet)" 0
check "the same headers as with the plugin off" "$(header_names quiet)" "$(header_names plain)"
check "the same answer" "$(answer quiet)" "$(answer plain)"
rid=$(hdr quiet x-bifrost-request-id)
for _ in $(seq 1 50); do [ "$(api "reports?request_id=$rid" | jq -r '.reports[0].status // ""')" = complete ] && break; sleep 0.2; done
check "the report is found by request ID, complete" "$(api "reports?request_id=$rid" | jq -c '[.reports[] | [.status, .outcome]]')" '[["complete","evidence_found"]]'
report quiet "$(api "reports?request_id=$rid" | jq -r '.reports[0].id')"
check "the usage endpoint says monitor" "$(api usage | jq -r .mode)" monitor
stop_gateway

check "no key value in the reports or the gateway logs" \
  "$(cat "$LIB_TMP"/{wave,chat,pages,quiet}.json "$LOG" "${LOG%.log}-monitor.log" | grep -cE 'tvly-[A-Za-z0-9]{8}|sk-bf-' || true)" 0

mkdir -p "$(dirname "$OUT")"
for n in wave chat pages quiet; do
  jq -c --arg n "$n" '{name: $n, outcome, verdict, claims: [.claims[] | {text, status, verdict, verdict_reason, quote_flagged: .quote.flagged,
    dropped_sources: .evidence.dropped_sources, sources: [.evidence.sources[] | {url, flagged, flag_reason}]}]}' "$LIB_TMP/$n.json"
done | jq -s --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{recorded_at: $at, mode: "mock", note: "Synthetic keys; mock LLM and mock Tavily. No page text recorded.", reports: .}' > "$OUT"
check "outcome record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
