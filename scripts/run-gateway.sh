#!/usr/bin/env bash
# Run the Bifrost gateway with a clean environment.
#
# Usage: scripts/run-gateway.sh <app-dir> [port]
# GATEWAY_LOG_LEVEL=debug|info|warn|error (default info).
#
# The gateway only sees PATH, HOME, TMPDIR, LANG and the non-empty values in
# .env. Without this, Bifrost picks up any OPENAI_*/ANTHROPIC_*/MISTRAL_* key
# in your shell when the app dir has no config.json (lib/config.go,
# autoDetectProviders), including credentials that belong to other tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:?usage: $0 <app-dir> [port]}"
PORT="${2:-8090}"
BIN="${BIFROST_BIN:-$ROOT/bifrost/tmp/bifrost-http}"

[ -x "$BIN" ] || { echo "gateway binary not found: $BIN" >&2; exit 1; }
mkdir -p "$APP_DIR"

env_args=(PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}")
if [ -f "$ROOT/.env" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [ -n "$value" ] && env_args+=("$key=$value")
  done < "$ROOT/.env"
fi

exec env -i "${env_args[@]}" "$BIN" -host 127.0.0.1 -port "$PORT" -app-dir "$APP_DIR" -log-style json -log-level "${GATEWAY_LOG_LEVEL:-info}"
