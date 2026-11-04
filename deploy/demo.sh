#!/usr/bin/env bash
# The before/after, against the demo stack (docker compose --profile demo up):
# a stale answer is served, audited and evicted; the same question then skips
# the cache and comes back flagged. The mock repeats its scripted answer; a real
# model would answer afresh.
set -Eeuo pipefail
GW="${GW:-http://127.0.0.1:8080}"
TOKEN="${TOKEN:-halflife-test-setup-token}" # synthetic default, from deploy/demo/config.json
Q="${Q:-Give me an overview of Acme Cloud.}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ask() {
  curl -s -m 30 -D "$TMP/headers" -o "$TMP/body" -X POST "$GW/v1/chat/completions" -H 'x-bf-vk: sk-bf-halflife-acme' \
    -H 'content-type: application/json' -d "$(jq -cn --arg q "$Q" '{model: "openai/ok", messages: [{role: "user", content: $q}]}')"
  grep -q ' 200' <(head -1 "$TMP/headers") || { echo "request failed: $(cut -c1-300 "$TMP/body")" >&2; exit 1; }
  tr -d '\r' < "$TMP/headers" | grep -i '^x-\(halflife\|bf-cache\)' || true
  jq -r '"answer: " + .choices[0].message.content' "$TMP/body"
}

echo "== first request"
ask
id=$(tr -d '\r' < "$TMP/headers" | awk -F': ' 'tolower($1)=="x-halflife-report"{print $2}')
echo "== audit (off the request path)"
for _ in $(seq 1 100); do
  curl -s -m 5 -o "$TMP/report" "$GW/api/halflife/reports/$id" -H "X-Bifrost-Setup-Token: $TOKEN"
  [ "$(jq -r .status "$TMP/report")" = complete ] && break
  sleep 0.2
done
jq -r '"verdict: \(.verdict) (\(.outcome))", (.claims[] | "  \(.text)\n    \(.verdict // .status): \(.verdict_reason // .status_reason // "")")' "$TMP/report"
echo "== same question again"
ask
echo "== dashboard: $GW/workspace/halflife"
