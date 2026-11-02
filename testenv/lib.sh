# Shared helpers for the gateway test scripts that need Redis. Source it after
# setting ROOT; it sets GW, MOCK and REDIS and installs an EXIT trap.
#
#   require_free_ports           refuse to run if the gateway or mock port answers
#   ensure_redis                 start the Redis container unless it is running
#   start_mock                   build and start the mock LLM provider
#   start_gateway CONFIG LOG [NS] start a gateway on 8090 from testenv/configs/CONFIG,
#                                with the semantic cache namespace set to NS if given
#   stop_gateway                 stop it (Halflife drains its audit queue)
#   check NAME GOT WANT          PASS/FAIL line; failures counted in $fails
#   finish                       print the verdict and exit non-zero on failures

GW=http://127.0.0.1:8090
MOCK=http://127.0.0.1:9101
REDIS=halflife-redis
LIB_TMP="$(mktemp -d)"
fails=0
_mock_pid="" _gw_pid="" _started_redis="" _namespaces=()

rcli() { docker exec "$REDIS" redis-cli "$@"; }

stop_gateway() { [ -n "$_gw_pid" ] && { kill "$_gw_pid" 2>/dev/null || true; wait "$_gw_pid" 2>/dev/null || true; }; _gw_pid=""; }

_cleanup() {
  stop_gateway
  [ -n "$_mock_pid" ] && { kill "$_mock_pid" 2>/dev/null || true; wait "$_mock_pid" 2>/dev/null || true; }
  if [ -n "$_started_redis" ]; then
    docker stop "$REDIS" >/dev/null 2>&1 || true
  else # bash 3.2: an empty "${a[@]}" is unbound under set -u
    for ns in ${_namespaces[@]+"${_namespaces[@]}"}; do rcli FT.DROPINDEX "$ns" DD >/dev/null 2>&1 || true; done
  fi
  rm -rf "$LIB_TMP"
}
trap _cleanup EXIT

require_free_ports() {
  for u in "$GW" "$MOCK"; do # a leftover mock would silently serve this run
    if curl -s -o /dev/null "$u"; then echo "$u is in use (stop the dev stack with: make down)" >&2; exit 1; fi
  done
}

ensure_redis() {
  docker info >/dev/null 2>&1 || { echo "Docker is not running (open -a Docker)" >&2; exit 1; }
  if ! docker ps --format '{{.Names}}' | grep -qx "$REDIS"; then
    docker run -d --rm --name "$REDIS" -p 127.0.0.1:6380:6379 redis:8.2.2 redis-server --save '' --appendonly no >/dev/null
    _started_redis=1
    for _ in $(seq 1 40); do rcli PING 2>/dev/null | grep -q PONG && return; sleep 0.25; done
    echo "redis did not start" >&2; exit 1
  fi
}

start_mock() {
  mkdir -p "$ROOT/logs" "$ROOT/bin"
  (cd "$ROOT/testenv" && go build -o "$ROOT/bin/mockllm" ./cmd/mockllm)
  MOCK_LLM_API_KEY=sk-halflife-mock "$ROOT/bin/mockllm" -fixtures "$ROOT/testenv/fixtures/llm.json" > "$ROOT/logs/$(basename "$0" .sh)-mockllm.log" 2>&1 &
  _mock_pid=$!
}

start_gateway() {
  local app="$LIB_TMP/app-$RANDOM" ns="${3:-}"
  mkdir -p "$app"
  if [ -n "$ns" ]; then
    _namespaces+=("$ns")
    jq --arg ns "$ns" '(.plugins[] | select(.name == "semantic_cache") | .config.vector_store_namespace) = $ns' \
      "$ROOT/testenv/configs/$1/config.json" > "$app/config.json"
  else
    cp "$ROOT/testenv/configs/$1/config.json" "$app/config.json"
  fi
  GATEWAY_APP="$app"
  GATEWAY_LOG_LEVEL=debug "$ROOT/scripts/run-gateway.sh" "$app" 8090 > "$2" 2>&1 &
  _gw_pid=$!
  for _ in $(seq 1 120); do curl -sf "$GW/health" >/dev/null && curl -sf "$MOCK/v1/models" >/dev/null && return; sleep 0.25; done
  echo "gateway ($1) did not start; see $2" >&2; exit 1
}

check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got: $2, want: $3)"; fails=$((fails+1)); fi; }

finish() { [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }; }
