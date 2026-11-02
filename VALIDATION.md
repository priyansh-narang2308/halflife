# Validation Log

Every claim that something works points to an entry here. Each entry says whether it ran against a **live** service or a **mock**.
Secrets are never printed: key checks report only whether a variable name exists.

## Task 01: Pre-flight checks (2026-11-01)

### Build window (live: event page)

Source: https://hackculture.io/hackathons/ai-global-hackathon, read at 00:16 IST.

- Schedule: "Online Elimination round 01 Nov 2026, 12:00 AM – 15 Nov 2026, 11:59 PM" (browser timezone `Asia/Calcutta`).
- Page metadata: `event:start_time 2026-10-09T02:30:00Z` (08:00 IST) and `event:end_time 2026-11-29T18:29:00Z` (23:59 IST). Event times are anchored to IST.
- Clock at check: `Sun Nov 1 00:16:48 IST 2026` = `Sat Oct 31 18:46:48 UTC 2026`.
- Result: **window open** under IST. Under UTC it would open at 18:30 UTC on 31 Oct, the same instant.

### Rules re-read (live: event page)

Relevant rules: 1 (core built during the hackathon; libraries and boilerplate allowed), 2 (disclose AI use), 3 (Discord mandatory), 5 (original work or licensed components), 6 (third-party tools within their licenses), 7 (submission must include a working demo, source code, description, problem, technologies, AI usage, and a demo video if required), 8 (one final project per team), 10 (judging criteria, unweighted).

### Tools

```
$ go version
go version go1.25.1 darwin/arm64
$ go env GOTOOLCHAIN
auto
$ ls ~/go/pkg/mod/golang.org/          # cached toolchains
toolchain@v0.0.1-go1.25.3 … go1.26.9, go1.27.1 (darwin-arm64)
$ docker --version
Docker version 29.9.2, build a82e528
$ docker info
failed to connect to the docker API at unix:///Users/priyanshnarang/.docker/run/docker.sock … daemon is not running
$ redis-server --version
Redis server v=8.6.3 … bits=64
$ redis-cli ping
Could not connect to Redis at 127.0.0.1:6379
```

Also present: git, gh (logged in), curl, jq, python3, node. Host: macOS 27.2, arm64, 73 GiB free.

### Credentials (names only)

```
$ env | cut -d= -f1 | grep -iE 'key|token|secret|tavily|openai|anthropic|gemini|groq|mistral|openrouter'
ANTHROPIC_API_KEY
ANTHROPIC_BASE_URL
ANTHROPIC_MODEL
CLAUDE_CODE_MESSAGING_TOKEN
```

- `TAVILY_API_KEY`: **not set**.
- `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, and other provider keys: **not set**.
- `ANTHROPIC_*`: set, but appears to belong to the Claude Code session (see PROGRESS.md, decision D3). Not used.

### Existing files preserved

`research/hackathon-strategy-report.md` and `research/phase2-engineering-audit.md` are unchanged and committed as-is.

## Task 02: Go 1.27.3 toolchain (2026-11-01)

Live: official Go module proxy and checksum database.

```
$ curl -s https://proxy.golang.org/golang.org/toolchain/@v/list | grep 'go1\.27\..*darwin-arm64'
v0.0.1-go1.27.0 … v0.0.1-go1.27.3.darwin-arm64
$ go env GOPROXY GOSUMDB
https://proxy.golang.org,direct
sum.golang.org
$ GOTOOLCHAIN=go1.27.3 go version
go: downloading go1.27.3 (darwin/arm64)
go version go1.27.3 darwin/arm64
$ cat ~/go/pkg/mod/cache/download/golang.org/toolchain/@v/v0.0.1-go1.27.3.darwin-arm64.ziphash
h1:yCdfDZ+GhmDNz9efAMlsprJWmFX/baYtnSkwvgeWipA=
```

Auto-switch check (scratch module with `go 1.27.3` in `go.mod`, as Bifrost's modules declare):

```
--- default GOTOOLCHAIN=auto, outside module:
go version go1.25.1 darwin/arm64
--- inside module declaring go 1.27.3:
go version go1.27.3 darwin/arm64
compiled with go1.27.3        # go run, prints runtime.Version()
vet ok
```

Result: **pass**. The base install is untouched; Go switches to 1.27.3 per module. Final confirmation inside the Bifrost modules happens in Task 04.

### Environment template

`.env.example` (committed) lists every key: `TAVILY_API_KEY`, `OPENROUTER_API_KEY`, optional `GROQ_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY`, and `REDIS_ADDR`. `.env` was created from it with mode 600 and empty values.

```
$ git check-ignore -v .env .env.example
.gitignore:2:.env	.env
.gitignore:4:!.env.example	.env.example     # negated: tracked
```

### OpenRouter (live: public docs and catalog, no key used)

- Bifrost v2.4.0 provider: `ModelProvider OpenRouter = "openrouter"` (`core/schemas/bifrost.go:72`); implementation in `core/providers/openrouter/`.
- https://openrouter.ai/docs/api-reference/limits: `:free` models allow 20 req/min; 50 req/day with < 10 credits ever purchased, 1,000 req/day with ≥ 10. A negative balance can return 402 even on free models.
- `GET https://openrouter.ai/api/v1/models`: 452 models, 14 `:free`. Free models that advertise `structured_outputs`: `nvidia/nemotron-3.5-super-vl:free`, `dots-studio/dots-3-note-preview:free`, `xingchen-agi/xing4.0-29b-a4b:free`, `liquid/lfm-2.5-2.6b:free`. The free catalog changes; the model is chosen in Task 27.

## Task 03: Bifrost source at the pinned commit (2026-11-01)

Live: GitHub. Command: `./scripts/bootstrap-bifrost.sh` (blobless, depth-1 clone of the tag, sparse checkout without `docs/`).

First run (clone, 1 min 31 s):

```
Cloning into '/Users/priyanshnarang/Developer/global-ai/bifrost'...
warning: refs/tags/transports/v2.4.0 9c6ac22ceb9794b7dafdceced5f25d93a43f18e4 is not a commit!
OK  pinned commit  e869c3f9adc96ea53c38694a21bb04a8e1085487 (transports/v2.4.0)
OK  GitHub tag     e869c3f9adc96ea53c38694a21bb04a8e1085487
OK  branches       upstream=e869c3f halflife=e869c3f (current: halflife)
OK  our commits    0 on halflife
```

The warning only means the tag is annotated (tag object `9c6ac22`); it peels to `e869c3f`. The script checks the local tag, the `upstream` branch and GitHub's `ls-remote` peeled tag against the pinned hash, and fails on any mismatch. A second run verifies the existing checkout without re-cloning or resetting it (same four `OK` lines).

Working-tree integrity:

```
$ git -C bifrost status --porcelain        # (empty: clean)
files on disk: 4760   skipped by sparse (docs/): 1453   total in commit: 6213
$ du -sh bifrost bifrost/.git
130M  bifrost      24M  bifrost/.git
$ git log -1 --format='%H %an %cd %s'
e869c3f9adc96ea53c38694a21bb04a8e1085487 Akshay Deo Thu Oct 29 12:42:08 2026 -0700 fix failing tests (#9306) --skip-ci
```

Blob hashes of the files the plan depends on match `HEAD`:

| File | Working tree = `HEAD` |
|---|---|
| `core/schemas/plugin.go` | `de2ce03e` |
| `transports/bifrost-http/server/plugins.go` | `c83231fe` |
| `plugins/semanticcache/main.go` | `7296e62d` |
| `plugins/governance/relays.go` | `a0f94928` |
| `core/relay/usage.go` | `beab8de4` |

Result: **pass**.

### Findings that shape later tasks

- `transports/go.mod` requires published versions (core v1.14.1, framework v1.11.1, semanticcache v1.7.4, governance v1.11.1, …) and has no `replace` lines. Release builds use `GOWORK=off` (`Makefile` L393–L410), so our plugin needs a `require` + `replace` there (Task 08).
- `make setup-workspace` (`Makefile` L1865–L1886) builds a `go.work` from `cli`, `core`, `framework`, `transports` and every `plugins/*` folder, so `plugins/halflife` will be included automatically in dev builds.
- `transports/bifrost-http/main.go:74` embeds the UI with `//go:embed all:ui`; `make build` runs `build-ui` (npm build and copy) first. Task 04 must satisfy this embed.
- Upstream ships `plugins/mocker` (an indirect dependency of transports). Task 05 will check whether it can serve as the mock provider before writing our own.

### Broken partial clone

The interrupted clone from the earlier session (480 MB `.git`, no commit checked out) was moved, not deleted, to `/private/tmp/claude-501/-Users-priyanshnarang--claude-spares-spare-BohcTC/c4f4f9a8-0738-42d0-8760-1277e9feef1c/scratchpad/broken-clone/bifrost`.

## Task 04: Build and run unmodified Bifrost (2026-11-01)

Live: npm registry, Go module proxy. Local: gateway on 127.0.0.1. No provider calls were made with project keys (none exist yet).

### Build

Command: `scripts/build-gateway.sh` (mirrors `make build` for a native macOS build; see the script header for the two UI-install differences).

```
$ GOWORK=off go mod download -x   (in transports/)      # 1,212 module fetches, 5 min 35 s
$ GOWORK=off go mod verify
all modules verified
$ go version          (in transports/)
go version go1.27.3 darwin/arm64                          # closes Task 02's last check
$ npm ci --ignore-scripts --legacy-peer-deps=false        # added 544 packages in 7s
$ npm run build                                           # vite build ✓ 9,446 modules; tsc --noEmit ✓; copy-build ✓
$ CGO_ENABLED=1 GOWORK=off go build -ldflags="-w -s -X main.Version=v2.4.0" -a -trimpath -tags sqlite_static -o ../../tmp/bifrost-http .
$ file bifrost/tmp/bifrost-http
Mach-O 64-bit executable arm64   (140,440,162 bytes, go1.27.3)
$ shasum -a 256 bifrost/tmp/bifrost-http
cae546ef7ee52e6e8445b0ce7f0c92407ab1d5caa494e5dd7e7ae36f80fb518b
```

Full scripted rebuild from a deleted binary: 1 min 6 s, **same SHA-256**, so the build is reproducible. `git -C bifrost status --porcelain` stays empty (all build outputs are gitignored upstream).

**UI build failure, root-caused and fixed without touching upstream files.** The first `npm ci` + `npm run build` failed:

```
Error: [vite]: Rolldown failed to resolve import "react-is" from ".../node_modules/recharts/es6/util/ReactUtils.js".
```

`ui/.npmrc` sets `legacy-peer-deps=true`. `react-is@19.2.6` is in `package-lock.json` but flagged `"peer": true` (a peer dependency of `recharts@3.8.1`), so `npm ci` skipped it. Passing `--legacy-peer-deps=false` installs exactly the lockfile version (543 → 544 packages) and the build passes. This may be an upstream issue worth reporting.

### Compiled modules = the source we audited

The binary links published module versions, not the tag's local folders (`transports/go.mod` has no `replace`):

```
dep github.com/maximhq/bifrost/core                  v1.14.1
dep github.com/maximhq/bifrost/framework             v1.11.1
dep github.com/maximhq/bifrost/plugins/governance    v1.11.1
dep github.com/maximhq/bifrost/plugins/semanticcache v1.7.4
dep github.com/maximhq/bifrost/plugins/logging       v1.11.1
… compat v0.5.3, maxim v1.7.14, mocker v1.6.14, modelcatalogresolver v1.1.14, otel v1.6.4, prompts v1.1.14, routing v1.2.4, telemetry v1.9.4
```

`diff -rq` of each published module against the tag's folder (excluding tests and `go.sum`): core, semanticcache, governance and logging differ only in `LICENSE` and `changelog.md`. Framework additionally differs in `warp/prompt.go` and `warp/topics.go`, which Halflife doesn't use. **The Phase 2 source findings apply to the compiled code.**

### Run (smoke test)

Command: `scripts/run-gateway.sh data/upstream-smoke-clean 8090`

```
health=200 after ~6s
GET  /health                 → 200 {"components":{"db_pings":"ok"},"status":"ok"}
GET  /                       → 200 text/html (Bifrost dashboard, <title>Bifrost</title>)
POST /v1/chat/completions    → 400 "failed to get config for provider openai: not found" (expected: no providers configured)
env var names seen by the gateway: HOME LANG PATH REDIS_ADDR TMPDIR
log: "successfully started bifrost, serving UI on http://127.0.0.1:8090"
log: plugin status active: routing, compat, model-catalog-resolver, telemetry, prompts, logging, governance
log: 0 error lines; 0 auto-detect lines
SIGTERM → "server gracefully shutdown" … "🏁 server stopped", exit 0
```

Result: **pass**.

### Findings

1. **Credential auto-detection.** The first smoke run (plain shell, port 8080) logged `auto-detected anthropic provider from environment variable ANTHROPIC_API_KEY` and called Anthropic list-models, which returned `invalid x-api-key`. Bifrost does this whenever the app dir has no `config.json` (`transports/bifrost-http/lib/config.go:9870`, for `OPENAI_*`, `ANTHROPIC_*`, `MISTRAL_*`). The key is Claude Code's session credential (decision D3), and the rejection confirms it isn't a direct Anthropic key. Checked without printing the value: `config.db` holds only the reference `env.ANTHROPIC_API_KEY`, never the value; `logs.db` holds neither. **Fix:** `scripts/run-gateway.sh` starts the gateway with `env -i`, passing only `PATH`, `HOME`, `TMPDIR`, `LANG` and non-empty `.env` values. Halflife runs will also use explicit `config.json` files.
2. **Port 8080 is taken** on this machine by an Apache `httpd` (PID 1587, `*:8080`). Halflife uses **8090**. The first run still served Bifrost on `127.0.0.1:8080` (`Server: fasthttp`), but 8090 avoids ambiguity.
3. **Management API is locked by default.** `GET /api/plugins` → 403 "dashboard auth is not configured and no setup token is set". Governance setup (virtual keys, budgets, relays) needs `BIFROST_SETUP_TOKEN` or `config.json`. A placeholder is now in `.env.example`.
4. **Default plugins** in a zero-config instance: routing, compat, model-catalog-resolver, telemetry, prompts, logging, governance. The semantic cache is off until configured (Task 16).

## Task 05: Deterministic mock servers (2026-11-02)

**All mocked.** No real LLM or Tavily calls. The synthetic keys `sk-halflife-mock`, `sk-bf-halflife-smoke` and `tvly-mock` are test values only.

Code: `testenv/` (Go module `github.com/priyansh-narang2308/halflife/testenv`, stdlib only).

| Component | What it does |
|---|---|
| `mockllm` | OpenAI-compatible `/v1/chat/completions` and `/v1/models`. Model name picks behaviour: `ok`, `slow-<ms>`, `fail-<status>` (429 adds `Retry-After`). Scripted replies by last user message; deterministic IDs (hash of request body) and timestamps; SSE streaming with optional usage chunk; optional bearer check; `/_mock/requests` and `/_mock/reset` counters |
| `mocktavily` | `/search` and `/extract` with bearer auth (401). Credits: basic/fast/ultra-fast 1, advanced 2; Extract 1 credit block per 5 successful URLs (×2 advanced). `usage.credits` only when `include_usage`. Query markers `[mock:400/429/432/433/434/500]` inject errors with Tavily's `{"detail":{"error":…}}` shape. Failed requests charge no credits |
| `fixtures/` | Synthetic data about a fictional company, Acme Cloud, on reserved `.example` domains. The LLM replies are deliberately stale against the Tavily fixtures (price $20 → $29, SDK 3.2.0 → 4.1.0, CEO changed) |

**Assumptions to reconcile in Task 21 (live Tavily):** the exact `usage` field shape, Extract's credit rounding, 434's message text, `response_time` type, and `published_date` presence.

Why not upstream's `plugins/mocker`: it answers inside `PreLLMHook` with a short-circuit (`plugins/mocker/main.go:516`, `:575`), so no provider attempt happens. Halflife must be tested on Bifrost's real provider path (attempts, failures, fallbacks, post-hooks), which needs an HTTP provider.

### Unit tests

```
$ go vet ./... && go test -race -count=1 -v ./...
--- PASS: TestScriptedAndDefaultReplies   --- PASS: TestDeterministicBodies
--- PASS: TestContentParts                --- PASS: TestInjectedFailures
--- PASS: TestLatency (0.12s)             --- PASS: TestStreaming
--- PASS: TestAuthAndValidation           --- PASS: TestCountsAndReset
--- PASS: TestModelsList
ok  github.com/priyansh-narang2308/halflife/testenv/mockllm     coverage: 94.2%
--- PASS: TestAuth                        --- PASS: TestSearchFixturesAndLimits
--- PASS: TestSearchCredits               --- PASS: TestSearchErrors
--- PASS: TestExtract                     --- PASS: TestStatsAndReset
ok  github.com/priyansh-narang2308/halflife/testenv/mocktavily  coverage: 90.8%
```

15/15 pass with the race detector; `gofmt -l` clean. The first run had 1 failure, a bug in the test (usage struct missing JSON tags), not in the mock.

### Gateway smoke test (real Bifrost binary + mock provider)

Command: `testenv/smoke-mock-llm.sh` (config: `testenv/configs/mock-llm/config.json`; gateway on 8090, mock on 9101).

```
PASS  no virtual key: refused
PASS  no virtual key: never reached provider
PASS  scripted reply: status
PASS  scripted reply: content
PASS  scripted reply: usage passed through
PASS  injected 503: status
PASS  streaming: reassembled text
PASS  streaming: terminated
PASS  fallback: status
PASS  fallback: served by fallback model
PASS  fallback: primary attempted once
PASS  fallback: fallback attempted once
mock request counts after fallback test: {"by_model":{"fail-500":1,"ok":1},"total":2}
fallback response extra_fields: {"provider":"openai","model_requested":"fail-500","resolved":"ok"}
ALL PASS
```

Gateway log: one error-level line, the injected 503 request (`http.status_code: 503`). The fallback request's failed primary attempt is not logged as a request error, because the request succeeded.

### Findings (each found by a failing run, then confirmed in source)

1. **Virtual keys are mandatory by default.** With a `config.json`, inference without `x-bf-vk` → 401 `virtual_key_required` (`plugins/governance/main.go:795`). `client.enforce_auth_on_inference` defaults to `true` on new deployments (`config.schema.json` L197). We keep it on; Halflife's per-app identity depends on it.
2. **`allowed_models: ["*"]` means "any model in Bifrost's catalog", not "anything".** `ModelCatalog.IsModelAllowedForProvider` (`framework/modelcatalog/models.go:330`) defers `*` to catalog lookup (datasheet plus live list-models). Unknown names → 403 `model_blocked`. Explicit names match without the catalog. Provider-key `models` behave the same: an unrestricted key on a provider with a catalog only serves catalog models (→ 400 `no_key_supports_model`). Consequence: OpenRouter free models must be in the catalog or listed explicitly (Tasks 21 and 27).
3. **The gateway rebuilds the response JSON.** It adds `extra_fields` (routing info, latency), `logprobs:null` and `system_fingerprint`, and reorders fields. Task 15's "unchanged response" test must compare gateway output with Halflife on vs off, not against the provider's raw bytes.
4. **Fallbacks reach the provider once per attempt with `max_retries: 0`.** That gives clean attempt counting for Task 13.

## Task 06: Local infrastructure (2 Nov 2026)

**Status:** done. Everything here runs locally with synthetic keys; no live API was called.

### Which Redis the semantic cache can use

Bifrost's Redis vector store refuses to start without the search module: "search module not available: please use Redis Stack or a Valkey bundle with search support (FT.* commands required)" (`framework/vectorstore/redis.go:82,95,112`).

| Candidate | `MODULE LIST` | `FT.CREATE` (vector index) | Usable |
|---|---|---|---|
| Homebrew `redis` 8.6.3 | `vectorset` only | `ERR unknown command` | No |
| Docker `redis:8.2.2` | `search`, `vectorset`, `ReJSON`, `bf`, `timeseries` | `OK`, index listed by `FT._LIST` | **Yes** |

Port 6379 was already taken by the user's own `falkordb` container, so Halflife's Redis listens on **127.0.0.1:6380** (D14). That container and `socraticode-qdrant` were not touched (checked before and after).

### One-command stack

`make up` → `scripts/dev-stack.sh up`:

```
redis       up
mockllm     up
mocktavily  up
gateway     up
make up  1.25s user 1.39s system 21% cpu 12.449 total
```

Per-service checks against the running stack:

```
--- redis via host port 6380
redis_version:8.2.2
vectorset timeseries search bf ReJSON
FT.CREATE stackprobe … VECTOR HNSW … DIM 2 → OK; FT._LIST → stackprobe; FT.DROPINDEX → OK
--- gateway -> mockllm (x-bf-vk: sk-bf-halflife-smoke)
The Acme Cloud Pro plan costs $20 per month and includes 100 GB of storage.
--- mocktavily
{"n":1,"url":"https://acme.example/pricing","usage":{"credits":1}}
--- second up is idempotent
mockllm already running / mocktavily already running / all 4 up
--- down
stack stopped; halflife-redis containers: 0; status: all 4 DOWN (exit 1)
--- user containers untouched
falkordb socraticode-qdrant
```

After `make down`, `make test` (15/15 under `-race`) and `make smoke` (12/12, ALL PASS) still pass.

### Design notes

- The gateway's app dir is recreated on each `up`, so it always loads `config.json` and never a stale config DB. The config defaults to `testenv/configs/mock-llm`; `STACK_CONFIG=…` overrides it (Task 16 adds the cache config).
- Redis runs with `--save '' --appendonly no`: the cache is disposable, so a restart gives a cold cache, which suits the cache tests.
- PIDs live in `data/dev-stack/run/`, and logs go to `logs/stack-<service>.log`. `scripts/dev-stack.sh logs gateway` tails them.

## Task 07: Halflife plugin skeleton (2 Nov 2026)

**Status:** done. Fork commit `ff8784d` on branch `halflife` (`git -C bifrost diff --stat upstream..halflife`: 7 files, all new under `plugins/halflife/`; no upstream file modified).

### What it is

- `Plugin` implements `schemas.LLMPlugin` (`PreRequestHook`, `PreLLMHook`, `PostLLMHook`) and `schemas.HTTPTransportPlugin` (`PreAuth`, `Pre`, `Post`, `ResponseHeaders`, `StreamChunk`). Compile-time assertions guard both.
- It deliberately does **not** implement `MCPPlugin` or `RelayPlugin`. The gateway picks hooks by type assertion (`InferPluginTypes` in `transports/bifrost-http/server/plugins.go`), so implementing them would add Halflife to those pipelines, including the Tavily relay it will itself call. A test pins this.
- Every hook returns its input unchanged. Comments record the lifecycle facts later tasks rely on: LLM hooks run once **per attempt**, while `HTTPTransportPostHook` runs once per request after fallbacks.
- `Init(ctx, *Config, logger)`: a nil config gives the defaults (`queue_size` 256, `workers` 2, `max_claims_per_response` 5, `tavily_relay` "tavily"); out-of-range values are rejected. `Cleanup` is idempotent.

### Tests (`GOWORK=off`, published `core v1.14.1`)

```
--- PASS: TestConfigDefaults
--- PASS: TestConfigValidate
--- PASS: TestConfigJSON
--- PASS: TestInit
--- PASS: TestImplementsGatewayInterfaces
--- PASS: TestLLMHooksPassThrough
--- PASS: TestHTTPHooksPassThrough
--- PASS: TestCleanupIdempotent
ok  github.com/maximhq/bifrost/plugins/halflife  coverage: 100.0% of statements
```

`go vet` and `gofmt -l` are clean, and the run used `-race`.

**Mutation check:** making `PostLLMHook` drop the response and `StreamChunkHook` drop the chunk fails `TestLLMHooksPassThrough` and `TestHTTPHooksPassThrough`. Restoring the code makes them pass again, so the pass-through tests catch a hook that alters traffic.

Not yet tested: loading inside the gateway (Tasks 08–09).

## Task 08: In-tree registration (2 Nov 2026)

**Status:** done. Fork commit `c7c0589`; details in `UPSTREAM_DIFF.md` (v1).

- `scripts/build-gateway.sh --skip-ui` builds `bifrost/tmp/bifrost-http` (SHA-256 `31c0e896…c01c2`). `go version -m` shows `dep github.com/maximhq/bifrost/plugins/halflife v0.1.0 => ../plugins/halflife`.
- `transports/go.sum` is byte-identical before and after (`cmp`).
- `go test ./bifrost-http/server/` passes. `go test ./bifrost-http/lib/` fails 5 tests in this shell ("expected 1 keys for provider anthropic, got 2") and passes with `env -i` (clean environment). Cause: Bifrost auto-imports the shell's `ANTHROPIC_API_KEY`, as found in Task 04 (D7). Unrelated to Halflife.

## Task 09: Plugin load smoke test (2 Nov 2026)

**Status:** done. Command: `testenv/smoke-halflife.sh` (also `make smoke`). Mock provider only; no live API called.

The script sends 6 request types to the gateway twice: with `testenv/configs/mock-llm` (no Halflife) and with `testenv/configs/halflife` (same config plus the `halflife` plugin entry), both at debug log level.

```
PASS  startup log: plugin initialized
PASS  startup log: plugin status active
PASS  shutdown log: plugin stopped
PASS  baseline has no halflife
PASS  debug log: halflife pre-hook ran on every attempt
PASS  pre-hooks: halflife always immediately before telemetry (first overall)
PASS  post-hooks: halflife always immediately after telemetry (last overall)
pre-hook order (one attempt):  halflife telemetry prompts logging governance routing compat model-catalog-resolver
post-hook order (one attempt): model-catalog-resolver compat routing governance logging prompts telemetry halflife
PASS  body non-empty / body identical / headers identical: ok, default, stream, fail503, fallback, novk  (18 checks)
PASS  status codes: ok/503/fallback/novk
ALL PASS
```

27/27 on 5 consecutive runs; exit 0; no ports left open.

### What "identical" means here

- Bodies are compared byte for byte after one normalisation: the gateway writes its own timing into `extra_fields.latency` and `extra_fields.upstream_latency` (ms). These differ by about 1 ms between identical requests **without** Halflife (shown by streaming the same request three times through one gateway), so they are zeroed on both sides. Nothing else is touched.
- Headers are compared after removing `Date`, `X-Bifrost-Request-Id`, `X-Request-Id`, `X-Bifrost-Trace-Id` and the latency headers, which change on every request.
- Task 15 repeats this at scale (N ≥ 1,000) with latency percentiles.

### Lifecycle facts observed (inputs to Tasks 10–14)

1. **Halflife's hooks see requests that governance rejects.** The no-VK request is refused inside governance's `PreLLMHook`, which runs after Halflife's, so Halflife's pre-hook runs (7 runs for 6 request types + 1 fallback attempt) and its post-hook gets the 401 as an error. Capture must only finalise successful responses.
2. **`PostLLMHook` runs once per stream chunk.** 20 post-hook runs: 6 for non-streaming attempts and 14 for the 14-chunk stream. Capture can't treat each `PostLLMHook` call as "the answer".
3. **The gateway issues a request ID** (`X-Bifrost-Request-Id`, same value as `X-Request-Id`), usable to link a Halflife report to the gateway's own logs (Task 11).

### Also changed

- `scripts/run-gateway.sh` takes `GATEWAY_LOG_LEVEL` (default `info`).
- `make up` now runs the gateway with Halflife enabled (`testenv/configs/halflife`); confirmed with `plugin status: halflife - active` in `logs/stack-gateway.log`.
- `make smoke` runs both smoke tests.

## Task 10: Final-response capture (2 Nov 2026)

**Status:** done. Fork commit `749649c` (`plugins/halflife/capture.go`, hook changes in `main.go`, `capture_test.go`).

### Probe: how the gateway's contexts relate

A temporary build logged each hook's root context pointer, the request ID, and a marker value (the probe code was removed afterwards; it was never committed). Request: `fail-500` with fallback to `ok`.

```
PROBE httppre   root=…67e0  reqid=<nil>
PROBE prellm    root=…7500  reqid=b3b242f9-…  sees=set-in-httppre
PROBE postllm   root=…7500  reqid=b3b242f9-…
PROBE prellm    root=…7500  reqid=b3b242f9-…  sees=set-in-postllm
PROBE postllm   root=…7500  reqid=b3b242f9-…
PROBE httppost  root=…67e0  reqid=<nil>  sees=set-in-httppre  hdr=b3b242f9-…  bodylen=695
```

1. Transport hooks and core hooks run on **different root contexts**. Values flow transport → core, but nothing set in the core hooks reaches `HTTPTransportPostHook`. Hence the slot pointer (D17).
2. All attempts of a request share one core context (the fallback's `PreLLMHook` saw the failed attempt's value), so per-attempt state must be overwritten, never accumulated.
3. The transport side has no request ID in its context; it is in the response header `X-Bifrost-Request-Id` (used in Task 11).

### Design

- `HTTPTransportPreHook` puts a fresh `*slot` on the transport context. `PreLLMHook` stores the last user message. `PostLLMHook` records each attempt's outcome, so the last attempt wins. `HTTPTransportPostHook` finalizes exactly once: a capture only when an attempt succeeded **and** the HTTP status is 2xx.
- Copied out of pooled objects: question (≤ 8 KiB), answer (≤ 64 KiB, cut on a rune boundary, `Truncated` flag), request type, serving provider/model, requested model, fallback flag. Supported: Chat Completions and the Responses API (only `output_text` blocks of assistant messages; reasoning and tool calls are excluded).
- Outcomes counted in `Stats`: captured, skipped failed / streaming / unsupported. The sink is a no-op until the worker pool (Task 12).
- Hooks still return their inputs unchanged.

### Unit tests (`GOWORK=off go test -race -cover`)

Tests model the gateway as observed: separate transport and core roots, one-way copy, plugin-scoped contexts released after each hook, and attempts numbered with `BifrostContextKeyFallbackIndex`.

| Test | Shows |
|---|---|
| `TestCaptureSuccessfulRequest` | All fields copied; nothing captured before the HTTP post-hook |
| `TestCaptureFallbackKeepsOnlySuccessfulAttempt` | Failed primary + successful fallback → 1 capture, `IsFallback` |
| `TestNoCaptureWhenRequestFails` | All attempts fail / governance rejection / success but non-2xx / no LLM hooks → 0 captures |
| `TestStreamingIsMarkedNotCaptured` | 5 chunk post-hooks → 0 captures, 1 streaming skip |
| `TestUnsupportedResponseTypes` | Embedding, text completion, chat without text → counted unsupported |
| `TestFinalizeOnce` | Two HTTP post-hooks → 1 capture |
| `TestNoSlotIsNoOp` | Go SDK use (no HTTP hooks) → nothing happens |
| `TestResponsesAPIAnswer`, `TestChatContentBlocks` | Text extraction for both APIs; last user message chosen |
| `TestClip` | Caps applied on rune boundaries |
| `TestCaptureDoesNotAliasSourceBuffers` | Overwriting the source bytes after capture leaves the capture intact |
| `TestConcurrentRequestsAreIsolated` | 200 parallel requests, ⅓ with fallbacks: every capture matches its own question |

`ok … coverage: 95.7% of statements`; `go vet` and `gofmt` clean.

**Mutation check:** removing the copy in `clip` makes `TestCaptureDoesNotAliasSourceBuffers` fail (the capture becomes `XXXX…`).

### Real gateway (`testenv/smoke-halflife.sh`, now 31 checks)

```
captures:
  chat_completion answer from openai/ok (75 bytes, fallback=false)
  chat_completion answer from openai/ok (28 bytes, fallback=false)
  chat_completion answer from openai/ok (68 bytes, fallback=true)
PASS  capture: one per successful request
PASS  capture: scripted answer
PASS  capture: fallback taken from the successful attempt
PASS  capture: stream marked, not captured
```

31/31 on 3 consecutive runs; bodies and headers still identical with Halflife on vs off. 75 bytes is the scripted Acme Pro reply in `fixtures/llm.json`.

### Bug found by the smoke test

The first run reported `fallback=false` for the fallback request. Core sets `RoutingInfo.IsFallback` only after post-hooks run, although the client sees it (`"is_fallback":true`, `X-Bifrost-Routing-Info-Is-Fallback: true`). The fix reads `BifrostContextKeyFallbackIndex` (D18). The unit tests had set `IsFallback` on the response directly, which hid the bug; they now model what core actually provides.

## Task 11: Report identity (2 Nov 2026)

**Status:** done. Fork commit `ee3c559`.

### What a captured answer now carries

- `ReportID`: `hlr_` + UUIDv7. Time-ordered, so IDs sort by creation. Sent to the client as `X-Halflife-Report`, and appended to `Access-Control-Expose-Headers` so browser clients such as the dashboard can read it.
- `RequestID`: the gateway's own request ID (`BifrostContextKeyRequestID`, equal to `X-Bifrost-Request-Id`), falling back to the response header if the context lacks it. This links a report to Bifrost's logs.
- `VirtualKeyID`, `VirtualKeyName`: the tenant, as resolved by governance. The raw `x-bf-vk` value is never read.
- `CapturedAt` (UTC), plus the model fields from Task 10.

### Hook timing this relies on (gateway source, `handlers/middlewares.go`)

For buffered responses the middleware runs `HTTPTransportPostHook` (finalize, which assigns the ID) **before** `HTTPTransportResponseHeadersHook` (which writes the header). For streams the headers hook runs first, so no ID exists yet; `TestReportHeaderBeforeFinalize` pins that.

### Unit tests

| Test | Shows |
|---|---|
| `TestCaptureSuccessfulRequest` (extended) | Request ID, virtual key ID and name, `CapturedAt`, report ID recorded |
| `TestReportHeader` | Header equals the capture's report ID; expose list extended once, even if the hook runs twice; no header for failed / streaming / unsupported / no slot |
| `TestReportHeaderBeforeFinalize` | No header when headers are written before finalize (streaming order) |
| `TestRequestIDFallsBackToResponseHeader` | Request ID from `x-bifrost-request-id`, matched case-insensitively |
| `TestVirtualKeySecretNeverRecorded` | With `x-bf-vk` = a secret on the context, no capture field contains it |
| `TestReportIDsUniqueAndTimeOrdered` | 10,000 IDs: unique, sorted in creation order, valid UUID version 7 |

`ok … coverage: 95.5% of statements` under `-race`.

### Real gateway (`testenv/smoke-halflife.sh`, now 45 checks)

```
captures:
  chat_completion answer from openai/ok (75 bytes, fallback=false) report=hlr_01a19d3c-2b19-748f-… request=0a781c56-… vk=vk-smoke
  chat_completion answer from openai/ok (28 bytes, fallback=false) report=hlr_01a19d3c-2b2c-78b2-… request=6a0114b0-… vk=vk-smoke
  chat_completion answer from openai/ok (68 bytes, fallback=true)  report=hlr_01a19d3c-2b62-772b-… request=9363b0a8-… vk=vk-smoke
PASS  report header: ok / default / fallback                         (UUIDv7 format)
PASS  report header matches capture and request id: ok / default / fallback
PASS  report header exposed to browsers: ok / default / fallback
PASS  no report header: stream / fail503 / novk
PASS  report ids distinct
```

45/45 on 3 consecutive runs; `make smoke` passes both smoke tests.

### Header comparison, refined

Halflife now changes response headers on purpose, so the on/off comparison removes `X-Halflife-Report` and the appended `, x-halflife-report`, then compares everything else. The first run failed: rewriting `Access-Control-Expose-Headers` moves it to the end of fasthttp's header list. The value was identical, only its position changed. HTTP header order carries no meaning, so header lines are now compared sorted, with the status line kept first. Every value is still compared exactly.

## Task 12: Bounded worker pool (2 Nov 2026)

**Status:** done (`plugins/halflife/pool.go`). Audits run a placeholder until the verifier exists (Task 24): it logs `halflife: audit report=<id> (no verifier yet)`, so arrival at a worker is observable.

### Behaviour

- `queue_size` buffered channel and `workers` goroutines started by `Init`.
- `submit` never blocks. Full queue or closed pool → dropped and counted. The request's report ID is withdrawn, so no `X-Halflife-Report` header is sent for a report that will never exist (D21).
- Each audit gets `context.WithTimeout(poolCtx, audit_timeout_seconds)`. A capture carries no request context, so audits outlive their requests by design.
- A panic or error in an audit is counted as failed; the worker keeps going.
- `Cleanup`: stop accepting, drain up to `drain_timeout_seconds`, then cancel running audits and count queued leftovers as abandoned (D22). An audit that ignores cancellation gets one more second; then `Cleanup` returns an error instead of hanging.
- New config: `audit_timeout_seconds` (default 60, range 1–600) and `drain_timeout_seconds` (default 5, range 1–60).

### Unit tests (`go test -race -count=10`: all pass; coverage 95.3%)

| Test | Shows |
|---|---|
| `TestPoolAuditsEverySubmission` | 100 captures, 4 workers → each audited exactly once |
| `TestPoolDropsWhenFullWithoutBlocking` | Worker busy + queue full: 1,000 submits rejected in well under 100 ms, counted as dropped |
| `TestPoolDrainsQueueOnClose` | 10 queued at shutdown → all 10 audited, 0 abandoned |
| `TestPoolDrainTimeoutCancelsAndAbandons` | Past the drain timeout: running audit sees cancellation (1 failed), 4 abandoned, close returns in < 500 ms |
| `TestPoolCloseGivesUpOnStuckAudit` | An audit ignoring its context can't hang shutdown; close reports it |
| `TestPoolAuditTimeoutAndErrors` | Timeout (`DeadlineExceeded`), error and panic → 3 failed; the next capture still audited |
| `TestPoolAuditContextHasOwnDeadline` | Audit context is live with the audit timeout as deadline |
| `TestPoolSubmitAfterCloseAndConcurrentClose` | 8 submitters racing 3 concurrent closes: no panic; enqueued = audited + abandoned; submit after close rejected |
| `TestPluginQueuesCapturesForAudit` | Through the plugin: 1 running + 1 queued get report headers and are audited in order; the 3rd is dropped and gets **no** header |

The first `-count=5` run failed once, from a bug in the test: its audit stub signalled on a channel with a buffer of 1 and blocked on the third audit, ignoring cancellation. That's the "stuck audit" case the pool is designed to give up on. The signal is now non-blocking.

### Real gateway (`testenv/smoke-halflife.sh`, 47 checks, 3/3 runs)

```
PASS  audits: one per report header
PASS  audits: exactly the reported ids
PASS  shutdown log: queue drained
"halflife: stopped (enqueued=3 dropped=0 audited=3 failed=0 abandoned=0 queued=0)"
```

Not tested through the gateway: saturation. With the placeholder audit, workers never fall behind; the unit tests cover it, and Task 15's load run reports drops.

## Task 13: Fallback correctness (2 Nov 2026)

**Status:** done. Command: `testenv/fallback-halflife.sh` (part of `make smoke`). Real gateway, mock provider. No plugin code changed: this tests Tasks 10–12 against every fallback shape.

Each scenario checks the attempts that reached the mock provider (per model), the HTTP status, the `X-Halflife-Report` header, and, after shutdown drains the queue, that the reported ID was captured once with the right fallback flag and audited exactly once. The whole set runs twice: `max_retries` 0 and 2.

| Scenario | Provider attempts (r=0 / r=2) | Status | Audits |
|---|---|---|---|
| `ok`, no fallbacks | ok×1 | 200 | 1, `fallback=false` |
| `fail-500` → `ok` | fail-500×1 / ×3, ok×1 | 200 | 1, `fallback=true` |
| `fail-500` → `fail-503` → `ok` | fail-500×1/×3, fail-503×1/×3, ok×1 | 200 | 1, `fallback=true` |
| `fail-429` → `ok` | fail-429×1 / ×3, ok×1 | 200 | 1, `fallback=true` |
| `fail-500` → `fail-503` | each ×1 / ×3 | 500 | **0**, no report header |
| `ok` → `fail-500` (unused) | ok×1 | 200 | 1, `fallback=false` |

Per run: `halflife: stopped (enqueued=5 dropped=0 audited=5 failed=0 abandoned=0 queued=0)`. 71/71 checks on 3 consecutive runs.

### Observed gateway behaviour

1. **Retries are invisible to plugins.** With `max_retries: 2`, each failing attempt reaches the provider 3 times, but Halflife's pre-hook still runs 11 times in both modes: once per attempt (primary or fallback), never per retry. So a retried attempt can't produce duplicate captures.
2. **All attempts failing returns the primary's error.** The response is 500 (from `fail-500`), not the last fallback's 503. The script's first run expected 503; that was a wrong guess on my part, now recorded as observed.

## Task 14: Recursion guard and streaming status (2 Nov 2026)

**Status:** done. Fork commit `d1c2f45`. Real gateway and mock provider only.

### Behaviour

- **Recursion guard.** New config `verifier_virtual_key`: the governance virtual key **ID** the verifier uses for its own LLM calls through the gateway. If a request's resolved VK ID matches, `PostLLMHook` records it as `verifier` on every attempt (the reason is sticky, like streaming), so it is never captured, queued or audited. Empty disables the guard; it never matches a request with no VK.
- **Other paths can't recurse either.** Tavily searches go through a Bifrost relay, and Halflife does not implement `RelayPlugin`, so relay calls never reach its hooks. In-process calls that skip the HTTP transport have no slot, so they are never captured.
- **`X-Halflife-Status` on every response:** `queued` (with `X-Halflife-Report`), or `not-audited; reason=<failed|streaming|unsupported|verifier|queue-full>`. It is added to `Access-Control-Expose-Headers` like the report header.
- **Streams are explicitly not audited in M1.** For streams the gateway writes headers before the stream's post-hooks run, so the status comes from `Content-Type: text/event-stream` when the outcome isn't known yet.

### Unit tests (`go test -race -count=3`: all pass; coverage 95.1%)

| Test | Proves |
|---|---|
| `TestVerifierTrafficNeverAudited` | Verifier VK: plain, primary-fail + fallback-success, and streaming requests all produce 0 captures (`SkippedVerifier: 3`); a tenant request right after is captured |
| `TestVerifierGuardDisabledByDefault` | No `verifier_virtual_key` → a request with an empty VK ID is still captured |
| `TestStatusHeaderWhenNotAudited` | failed, non-2xx, unsupported, streaming, verifier → matching `not-audited` status, no report, header exposed |
| `TestStatusHeaderBeforeFinalize` | Buffered response before finalize → no headers; SSE response before its post-hooks → `not-audited; reason=streaming` |
| `TestPluginQueuesCapturesForAudit` (extended) | Full queue → `not-audited; reason=queue-full` |
| `TestConfigDefaults` / `TestConfigJSON` (extended) | `verifier_virtual_key` decoded and trimmed |

### Real gateway (`testenv/smoke-halflife.sh`, 60 checks, 2/2 runs; `make smoke` all pass)

Both test configs gain a second virtual key, `vk-verifier` (synthetic value `sk-bf-halflife-verifier`); the Halflife config sets `verifier_virtual_key: "vk-verifier"`. A seventh request is sent with that key.

| Request | Status | `X-Halflife-Status` | Captured |
|---|---|---|---|
| ok, default, fallback | 200 | `queued` | yes (3) |
| stream | 200 | `not-audited; reason=streaming` | no |
| fail503 | 503 | `not-audited; reason=failed` | no |
| novk | 401 | `not-audited; reason=failed` | no |
| verifier | 200 | `not-audited; reason=verifier` | **no**: `halflife: verifier request not audited` logged once; no capture with `vk=vk-verifier` |

The verifier request still reaches the provider and its body is byte-identical with Halflife off. Shutdown totals are unchanged: `enqueued=3 … audited=3`. The on/off header comparison now removes all `X-Halflife-*` headers and their expose-list entries.
