#!/usr/bin/env bash
# Local development stack: Redis (with the search module), mock LLM provider,
# mock Tavily and the Bifrost gateway.
#
# Usage: scripts/dev-stack.sh up|down|status|logs [service]
#
#   redis       127.0.0.1:6380  Docker redis:8.2.2 (search + vectorset modules)
#   mockllm     127.0.0.1:9101  synthetic key sk-halflife-mock
#   mocktavily  127.0.0.1:9102  synthetic key tvly-halflife-mock
#   gateway     127.0.0.1:8090  app dir data/dev-stack, config from
#                               testenv/configs/mock-llm (override: STACK_CONFIG)
#
# Homebrew Redis is not enough: Bifrost's Redis vector store needs FT.*
# (framework/vectorstore/redis.go), which ships only in builds with the search
# module. Redis data is ephemeral; the semantic cache is rebuilt on each "up".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/data/dev-stack/run"
APP_DIR="$ROOT/data/dev-stack/app"
LOGS="$ROOT/logs"
CONFIG="${STACK_CONFIG:-$ROOT/testenv/configs/mock-llm/config.json}"
REDIS_IMAGE=redis:8.2.2
REDIS_CONTAINER=halflife-redis
REDIS_PORT="${REDIS_PORT:-6380}"
GW_PORT="${GW_PORT:-8090}"

services=(redis mockllm mocktavily gateway)

health() {
  case "$1" in
    redis)      docker exec "$REDIS_CONTAINER" redis-cli PING 2>/dev/null | grep -q PONG ;;
    mockllm)    curl -sf http://127.0.0.1:9101/v1/models >/dev/null ;;
    mocktavily) curl -sf http://127.0.0.1:9102/_mock/requests >/dev/null ;;
    gateway)    curl -sf "http://127.0.0.1:$GW_PORT/health" >/dev/null ;;
  esac
}

wait_healthy() {
  for _ in $(seq 1 120); do health "$1" && return 0; sleep 0.25; done
  echo "$1 did not become healthy; see logs/stack-$1.log" >&2
  return 1
}

start_bg() { # name, command...
  local name="$1"; shift
  if [ -f "$RUN/$name.pid" ] && kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
    echo "$name already running"; return
  fi
  nohup "$@" > "$LOGS/stack-$name.log" 2>&1 &
  echo $! > "$RUN/$name.pid"
}

up() {
  mkdir -p "$RUN" "$APP_DIR" "$LOGS" "$ROOT/bin"
  docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)" >&2; exit 1; }

  if ! docker ps --format '{{.Names}}' | grep -qx "$REDIS_CONTAINER"; then
    docker run -d --rm --name "$REDIS_CONTAINER" -p "127.0.0.1:$REDIS_PORT:6379" "$REDIS_IMAGE" \
      redis-server --save '' --appendonly no > /dev/null
  fi
  wait_healthy redis
  docker exec "$REDIS_CONTAINER" redis-cli MODULE LIST | grep -qx search \
    || { echo "redis is missing the search module" >&2; exit 1; }

  (cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm && go build -o "$ROOT/bin/mocktavily" ./cmd/mocktavily)
  start_bg mockllm env MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json"
  start_bg mocktavily env MOCK_TAVILY_API_KEY=tvly-halflife-mock "$ROOT/bin/mocktavily" -fixtures "$ROOT/testenv/fixtures/tavily.json"
  wait_healthy mockllm
  wait_healthy mocktavily

  # Fresh app dir each time so the gateway always loads config.json, not a
  # stale config DB from an earlier run.
  if ! health gateway; then
    rm -rf "$APP_DIR" && mkdir -p "$APP_DIR"
    cp "$CONFIG" "$APP_DIR/config.json"
    start_bg gateway "$ROOT/scripts/run-gateway.sh" "$APP_DIR" "$GW_PORT"
  fi
  wait_healthy gateway
  status
}

down() {
  for name in gateway mocktavily mockllm; do
    if [ -f "$RUN/$name.pid" ]; then
      kill "$(cat "$RUN/$name.pid")" 2>/dev/null || true
      rm -f "$RUN/$name.pid"
    fi
  done
  docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1 || true
  echo "stack stopped"
}

status() {
  local bad=0
  for s in "${services[@]}"; do
    if health "$s"; then printf '%-11s up\n' "$s"; else printf '%-11s DOWN\n' "$s"; bad=1; fi
  done
  return $bad
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  logs) tail -n "${LINES:-40}" "$LOGS/stack-${2:?service name}.log" ;;
  *) echo "usage: $0 up|down|status|logs <service>" >&2; exit 2 ;;
esac
