#!/usr/bin/env bash
# Runs the baselines over the HL-Claims dev split. By default it replays
# eval/recordings: no key, credit or network needed. LIVE=1 records anything
# missing, within the proxy's call limits (MAX_LLM, MAX_TAVILY).
#
#   PER_STRATUM=2  claims per stratum; 0 runs the whole dev split
#   RUNS=eval/runs where to write
#   REC=eval/recordings where recordings are kept
#   STRATA=a,b     only these strata
#   ONLY=S3        only these systems
#   VERIFIER_MAX_TOKENS=4096  part of each recorded request; changing it needs LIVE=1
set -Eeuo pipefail
trap 'echo "run.sh: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/testenv/lib.sh"
LIVE="${LIVE:-}" PER_STRATUM="${PER_STRATUM:-2}" RUNS="${RUNS:-$ROOT/eval/runs}" REC="${REC:-$ROOT/eval/recordings}"
STRATA="${STRATA:-}" ONLY="${ONLY:-S0 S1 S2 S3}"
PROXY=http://127.0.0.1:9103
MODELS="nvidia/nemotron-3.5-super-vl:free xingchen-agi/xing4.0-29b-a4b:free openrouter/free"

curl -s -o /dev/null "$PROXY" && { echo "$PROXY is in use" >&2; exit 1; }
require_free_ports
mkdir -p "$RUNS" "$ROOT/logs" "$ROOT/bin"
(cd "$ROOT/testenv" && go build -o "$ROOT/bin/replayproxy" ./cmd/replayproxy)

proxy_args=(-dir "$REC" -max-llm "${MAX_LLM:-60}" -max-tavily "${MAX_TAVILY:-30}")
if [ -n "$LIVE" ]; then
  for k in OPENROUTER_API_KEY TAVILY_API_KEY; do grep -q "^$k=." "$ROOT/.env" || { echo "$k is not set in .env" >&2; exit 1; }; done
  (set -a; source "$ROOT/.env"; set +a; exec "$ROOT/bin/replayproxy" -record "${proxy_args[@]}") > "$ROOT/logs/eval-proxy.log" 2>&1 &
else
  "$ROOT/bin/replayproxy" "${proxy_args[@]}" > "$ROOT/logs/eval-proxy.log" 2>&1 &
fi
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true; _cleanup' EXIT
for _ in $(seq 1 40); do curl -s -o /dev/null "$PROXY/_replay/stats" && break; sleep 0.25; done

select=(--per-stratum "$PER_STRATUM")
[ -z "$STRATA" ] || select+=(--strata "$STRATA")
python3 "$ROOT/eval/run.py" S3 --out /dev/null "${select[@]}" --fixtures "$LIB_TMP/llm.json"
export MOCK_LLM_FIXTURES="$LIB_TMP/llm.json"
start_mock

config() { # verify_all -> config path
  jq --arg ms "$MODELS" --arg proxy "$PROXY" --argjson all "$1" --argjson max "${VERIFIER_MAX_TOKENS:-4096}" '
    .providers.openrouter = {keys: [{name: "openrouter", value: "proxy-holds-the-key", models: ($ms | split(" ")), weight: 1.0}],
                             network_config: {base_url: $proxy, default_request_timeout_in_seconds: 120, max_retries: 0}}
    | (.governance.virtual_keys[] | select(.id == "vk-verifier-acme") | .provider_configs)
        += [{provider: "openrouter", allowed_models: ($ms | split(" ")), key_ids: ["*"], weight: 1.0}]
    | (.governance.budgets[] | select(.id | test("acme")) | .max_limit) = 100
    | (.relays[] | select(.name == "tavily")) |= (.base_url = $proxy | .credential.value = "proxy-holds-the-key")
    | (.plugins[] | select(.name == "halflife") | .config) += {verifier_models: ($ms | split(" ") | map("openrouter/" + .)), verifier_reasoning_effort: "low",
        verifier_max_tokens: $max, max_claims_per_response: 3, audit_timeout_seconds: 170, workers: 1, verify_all: $all}
  ' "$ROOT/testenv/configs/m1/config.json" > "$LIB_TMP/eval-$1.json"
  echo "$LIB_TMP/eval-$1.json"
}

wanted() { [[ " $ONLY " == *" $1 "* ]]; }
for system in S0 S1; do
  wanted "$system" && python3 "$ROOT/eval/run.py" "$system" --out "$RUNS/$system.jsonl" "${select[@]}"
done
for system in S3 S2; do
  wanted "$system" || continue
  start_gateway "$(config "$([ "$system" = S2 ] && echo true || echo false)")" "$ROOT/logs/eval-$(echo "$system" | tr A-Z a-z)-gateway.log"
  python3 "$ROOT/eval/run.py" "$system" --out "$RUNS/$system.jsonl" "${select[@]}"
  stop_gateway
done

curl -s "$PROXY/_replay/stats"; echo
python3 "$ROOT/eval/score.py" "$RUNS" --out "$RUNS/results.json" > /dev/null
echo "wrote $RUNS/results.json"
