#!/usr/bin/env bash
# The mock demo on a public ngrok link, for live judging. The stack runs on this
# machine. The setup token in the repo is public, so this replaces it with a
# fresh one for the session; share it only with the judges.
#
#   NO_TUNNEL=1 ./deploy/share.sh    starts the stack and stops short of ngrok
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GATEWAY_PORT:-8095}"
cd "$ROOT"

TOKEN="$(openssl rand -hex 16)"
CONFIG="$ROOT/data/share-config.json" # data/ is gitignored
export GATEWAY_PORT="$PORT" HALFLIFE_CONFIG="$CONFIG"
stop() { docker compose --profile demo down -v > /dev/null 2>&1 || true; rm -f "$CONFIG"; }
trap stop EXIT
stop

mkdir -p "$(dirname "$CONFIG")"
jq --arg t "$TOKEN" '.setup_token = $t' deploy/demo/config.json > "$CONFIG"
chmod 644 "$CONFIG" # read by the container's own user
docker compose --profile demo up -d --build
for _ in $(seq 1 90); do
  [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health")" = 200 ] && break
  sleep 1
done
[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health")" = 200 ] || { echo "gateway did not start" >&2; exit 1; }
GW="http://127.0.0.1:$PORT" TOKEN="$TOKEN" "$ROOT/deploy/demo.sh" > /dev/null

echo "Dashboard path: /workspace/halflife"
echo "Setup token for this session: $TOKEN"
if [ -n "${NO_TUNNEL:-}" ]; then
  echo "Stack is up on http://127.0.0.1:$PORT. Press Enter to stop."
  read -r _ || true
else
  ngrok http "$PORT"
fi
