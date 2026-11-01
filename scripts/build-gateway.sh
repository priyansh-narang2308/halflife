#!/usr/bin/env bash
# Build the bifrost-http gateway from ./bifrost the way upstream's
# `make build` does on macOS, writing bifrost/tmp/bifrost-http.
#
# Usage: scripts/build-gateway.sh [--skip-ui]
#
# Differences from `make build`, both about the UI install only:
#   --ignore-scripts         don't run third-party npm install scripts
#   --legacy-peer-deps=false ui/.npmrc sets legacy-peer-deps=true, which makes
#                            `npm ci` skip react-is@19.2.6 (a lockfile peer
#                            dependency of recharts) and the UI build fails
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/bifrost"
LOGS="$ROOT/logs"
VERSION="${VERSION:-v2.4.0}"
mkdir -p "$LOGS"

if [ "${1:-}" != "--skip-ui" ]; then
  echo "==> UI: npm ci"
  (cd "$SRC/ui" && npm ci --ignore-scripts --no-audit --no-fund --legacy-peer-deps=false) > "$LOGS/ui-npm-ci.log" 2>&1
  echo "==> UI: build, typecheck, copy into transports/bifrost-http/ui"
  (cd "$SRC/ui" && npm run build) > "$LOGS/ui-build.log" 2>&1
fi
[ -f "$SRC/transports/bifrost-http/ui/index.html" ] || { echo "UI build output missing; run without --skip-ui" >&2; exit 1; }

echo "==> Go: build bifrost-http ($VERSION)"
(cd "$SRC/transports/bifrost-http" && CGO_ENABLED=1 GOWORK=off go build \
  -ldflags="-w -s -X main.Version=$VERSION" \
  -a -trimpath -tags "sqlite_static" \
  -o ../../tmp/bifrost-http .) > "$LOGS/go-build.log" 2>&1

echo "==> Built $SRC/tmp/bifrost-http"
(cd "$SRC/transports" && go version -m ../tmp/bifrost-http | sed -n '1p;/maximhq\/bifrost\/core/p')
shasum -a 256 "$SRC/tmp/bifrost-http"
