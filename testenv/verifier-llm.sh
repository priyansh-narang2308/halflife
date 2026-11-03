#!/usr/bin/env bash
# Verifier LLM client through the real gateway: Halflife's structured-output
# client (bifrost/plugins/halflife/llm.go) calls /v1/chat/completions with
# Acme's verifier key, a JSON schema as response_format, and Bifrost request
# fallbacks. The client runs as the plugin's TestLLMThroughGateway, driven by
# this script; config testenv/configs/m1 with an overlay.
#
#   default   mock LLM and mock Tavily; no external call
#   LIVE=1    three claim checks on free OpenRouter models (no Tavily call,
#             $0). Needs OPENROUTER_API_KEY in .env; the script never reads it.
#
# Writes testenv/results/verifier-llm-{mock,live}.json. No key value.
set -Eeuo pipefail
trap 'echo "verifier-llm.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LIVE="${LIVE:-}"
MODE=$([ -n "$LIVE" ] && echo live || echo mock)
LOG="$ROOT/logs/verifier-llm-$MODE-gateway.log"
OUT="$ROOT/testenv/results/verifier-llm-$MODE.json"
VK=sk-bf-halflife-verifier-acme # synthetic, from the config
# Free on OpenRouter with structured outputs (listed 3 Nov 2026); the first is
# asked, the rest are Bifrost fallbacks.
LIVE_MODELS="nvidia/nemotron-3.5-super-vl:free xingchen-agi/xing4.0-29b-a4b:free openrouter/free"
# Reasoning models spent a whole 1024-token limit thinking on the Go case with
# no effort set (measured; recorded in VALIDATION.md), so live runs ask for low.
REASONING=$([ -n "$LIVE" ] && echo low || echo "")
GO_PROMPT=$'Claim: The latest stable version of Go is 1.25.\nEvidence: Go 1.27 was released on 11 August 2026. It is the latest stable release.'

CONFIG="$LIB_TMP/verifier-llm.json"
if [ -n "$LIVE" ]; then
  grep -q '^OPENROUTER_API_KEY=.' "$ROOT/.env" 2>/dev/null || { echo "OPENROUTER_API_KEY is not set in .env" >&2; exit 1; }
  MODELS=$(for m in $LIVE_MODELS; do printf 'openrouter/%s,' "$m"; done | sed 's/,$//')
  jq --arg ms "$LIVE_MODELS" --arg models "$MODELS" '
    .providers.openrouter = {keys: [{name: "openrouter", value: "env.OPENROUTER_API_KEY", models: ($ms | split(" ")), weight: 1.0}],
                             network_config: {default_request_timeout_in_seconds: 90, max_retries: 1}}
    | (.governance.virtual_keys[] | select(.id == "vk-verifier-acme") | .provider_configs)
        += [{provider: "openrouter", allowed_models: ($ms | split(" ")), key_ids: ["*"], weight: 1.0}]
    | (.plugins[] | select(.name == "halflife") | .config) += {verifier_models: ($models | split(",")), verifier_reasoning_effort: "low"}
  ' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"
else
  MODELS=openai/fail-500,openai/ok # the first fails, so Bifrost's fallback answers
  jq --arg models "$MODELS" '
    (.governance.virtual_keys[] | select(.id == "vk-verifier-acme") | .provider_configs[0].allowed_models) = ["ok", "fail-500"]
    | (.plugins[] | select(.name == "halflife") | .config.verifier_models) = ($models | split(","))
  ' "$ROOT/testenv/configs/m1/config.json" > "$CONFIG"
fi

echo "building the plugin's test binary"
(cd "$ROOT/bifrost/plugins/halflife" && GOWORK=off go test -c -o "$LIB_TMP/halflife.test" . 2>&1 | grep -v '^go: ' || true)
[ -x "$LIB_TMP/halflife.test" ] || { echo "test binary did not build" >&2; exit 1; }

# judge name models prompt -> $LIB_TMP/name.json (the client's outcome)
judge() {
  HALFLIFE_GW_URL="$GW" HALFLIFE_GW_VK="$VK" HALFLIFE_GW_MODELS="$2" HALFLIFE_GW_PROMPT="$3" HALFLIFE_GW_REASONING="$REASONING" HALFLIFE_GW_OUT="$LIB_TMP/$1.json" \
    "$LIB_TMP/halflife.test" -test.run '^TestLLMThroughGateway$' -test.count=1 > "$LIB_TMP/$1.testlog" 2>&1 \
    || { cat "$LIB_TMP/$1.testlog" >&2; return 1; }
  echo "$1: $(jq -c '{check, error, model: .result.model, fallback: .result.fallback, calls: .result.calls, malformed: .result.malformed}' "$LIB_TMP/$1.json")"
}
j() { jq -c "$2" "$LIB_TMP/$1.json"; }
captured() { grep -c '"halflife: captured ' "$LOG" || true; }

require_free_ports
start_mock
[ -z "$LIVE" ] && start_mock_tavily
start_gateway "$CONFIG" "$LOG"
echo "mode: $MODE"
check "startup log: verifier models configured" \
  "$(grep -c "\"halflife: initialized (.*verifier_models=$(echo "$MODELS" | tr ',' '\n' | wc -l | tr -d ' ') " "$LOG")" 1
before=$(captured)
cases=()

if [ -z "$LIVE" ]; then
  echo "--- a schema-valid reply, through a Bifrost fallback"
  curl -s -X POST "$MOCK/_mock/reset" >/dev/null
  judge valid "$MODELS" "$GO_PROMPT"; cases+=(valid)
  check "decoded and validated" "$(j valid .check)" '{"verdict":"CONTRADICTED","quote":"Go 1.27 was released on 11 August 2026."}'
  check "one call; Bifrost's fallback answered" "$(j valid '.result | [.calls, .malformed, .fallback, .model]')" '[1,0,true,"ok"]'
  check "the provider received the schema as strict json_schema" \
    "$(curl -s "$MOCK/_mock/requests" | jq -c '[.last_response_format, .by_model["fail-500"], .by_model.ok]')" '["json_schema:claim_check:strict",1,1]'

  echo "--- a reply that never matches the schema"
  judge malformed openai/ok "Claim: something with no scripted reply."; cases+=(malformed)
  check "one corrective retry, then reported malformed, no object" \
    "$(j malformed '[.malformed, .result.calls, .result.malformed, .check]')" '[true,2,2,null]'

  echo "--- the verifier key's budget spent by its searches"
  for q in "Acme Cloud Pro price" "Acme SDK latest version"; do
    curl -s -o /dev/null -X POST "$GW/relay/tavily/search" -H "x-bf-vk: $VK" -H 'content-type: application/json' \
      -d "$(jq -cn --arg q "$q" '{query: $q, search_depth: "basic", include_usage: true}')"
  done
  sleep 1 # charges land after the reply
  judge spent "$MODELS" "$GO_PROMPT"; cases+=(spent)
  check "402 reported as budget spent, not retried" "$(j spent '[.budget_spent, .result.calls, .check]')" '[true,1,null]'
else
  echo "--- three claim checks on free models"
  judge go "$MODELS" "$GO_PROMPT"; cases+=(go)
  judge ceo "$MODELS" $'Claim: Sam Altman is the CEO of OpenAI.\nEvidence: Sam Altman is the chief executive officer of OpenAI, a role he returned to in November 2023 after a brief removal by the board.'
  cases+=(ceo)
  judge price "$MODELS" $'Claim: Acme Cloud Pro costs $49 per month.\nEvidence: Acme Cloud opened a new data centre in Frankfurt this year.'
  cases+=(price)
  valid=0
  for c in "${cases[@]}"; do [ "$(j "$c" '.check != null')" = true ] && valid=$((valid + 1)); done
  check "every call ended in a schema-valid object or a reported failure" \
    "$(for c in "${cases[@]}"; do j "$c" '(.check != null) != (.error != null)'; done | sort -u | paste -sd, -)" true
  check "at least one live reply validated against the schema" "$([ "$valid" -ge 1 ] && echo yes || echo "no ($valid)")" yes
  echo "schema-valid replies: $valid of ${#cases[@]}; expected verdicts CONTRADICTED, SUPPORTED, UNVERIFIABLE"
  echo "verdicts: $(for c in "${cases[@]}"; do printf '%s=%s ' "$c" "$(j "$c" '.check.verdict // (if .truncated then "truncated" elif .malformed then "malformed" else "failed" end)' | tr -d '"')"; done)"
fi

check "the verifier's own calls were never captured for audit" "$(( $(captured) - before ))" 0

ids=$(for c in "${cases[@]}"; do j "$c" '.result.gateway_request_ids[]' | tr -d '"'; done | sort -u)
stop_gateway # flushes the request log
rows=$(for id in $ids; do sqlite3 -separator ' ' "$GATEWAY_APP/logs.db" "select virtual_key_id, customer_id from logs where id = '$id'"; done | sort -u | paste -sd, -)
check "every call is in Bifrost's request log on Acme's verifier key and customer" "$rows" "vk-verifier-acme cust-acme"
check "no key value in the outcomes or the gateway log" \
  "$(cat "$LIB_TMP"/*.json "$LOG" | grep -cE 'sk-or-|tvly-[A-Za-z0-9]{8}' || true)" 0

mkdir -p "$(dirname "$OUT")"
for c in "${cases[@]}"; do jq -c --arg n "$c" '{name: $n} + .' "$LIB_TMP/$c.json"; done \
  | jq -s --arg mode "$MODE" --arg models "$MODELS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reasoning "$REASONING" '{recorded_at: $at, mode: $mode, models: ($models | split(",")), reasoning_effort: $reasoning, note: "Synthetic keys; no credential recorded.", cases: .}' > "$OUT"
check "outcome record holds no virtual key value" "$(grep -c 'sk-bf-' "$OUT" || true)" 0
echo "wrote $OUT"
finish
