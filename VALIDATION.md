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

**Status:** done. Fork commit `cfc3697` on branch `halflife` (`git -C bifrost diff --stat upstream..halflife`: 7 files, all new under `plugins/halflife/`; no upstream file modified).

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

**Status:** done. Fork commit `e3e1f1c`; details in `UPSTREAM_DIFF.md` (v1).

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

**Status:** done. Fork commit `b0a1657` (`plugins/halflife/capture.go`, hook changes in `main.go`, `capture_test.go`).

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

**Status:** done. Fork commit `2e9a928`.

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

**Status:** done. Fork commit `2cb9684`. Real gateway and mock provider only.

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

## Task 15: Overhead and integrity (2 Nov 2026)

**Status:** done. Command: `make bench` (`testenv/bench-halflife.sh`). Tool: `testenv/cmd/hlbench` (3 unit tests: percentile, timing normalization, rounding). No plugin code changed. Mock provider, synthetic keys. Machine: Apple M4 (10 cores) laptop, everything on localhost.

### Method

- **Same binary, fresh gateways.** Each comparison starts two new gateways: A on 8090 without Halflife and B on 8091, both at info log level in front of the same mock provider. Both stop afterwards.
- **A/A control.** The control runs the same comparison with B *also* without Halflife. Any gap it shows is noise between two processes.
- **Paired, alternating requests.** Each pair sends the same prompt (rotating over the 3 fixture questions) to A and B back to back, alternating which goes first. Latency runs from send to the last body byte.
- **Run size.** 200 warm-up pairs, then **2,000 measured pairs**, with 1 and then 16 pairs in flight.
- **Body check.** Bodies are SHA-256 compared after zeroing `extra_fields.latency` and `upstream_latency`, the gateway's own timing fields.
- **Paired median delta.** The headline is the median of (B − A) over pairs, so drift during a run cancels out.
- **Scope.** This measures the request path only. Audits run on Halflife's workers, and in M1 the audit is still the placeholder (no network I/O).

### Results (3 consecutive runs; JSON for the last in `testenv/results/`)

Paired median delta, B − A:

| In flight | Control (off vs off) | Halflife (off vs on) |
|---|---|---|
| 1 | +0.1, −0.4, +0.5 µs | **+9.6, +8.4, +7.8 µs** |
| 16 | +200.9, −175.8, −100.0 µs | −20.3, +31.3, +30.6 µs |

Last run, full distribution (µs):

| | A p50 | A p95 | A p99 | B p50 | B p95 | B p99 |
|---|---|---|---|---|---|---|
| control, 1 in flight | 215.3 | 276.0 | 634.0 | 215.8 | 278.5 | 570.5 |
| Halflife, 1 in flight | 217.1 | 261.3 | 602.3 | 225.3 | 281.8 | 575.0 |
| control, 16 in flight | 878.7 | 3485.1 | 7865.9 | 778.5 | 2751.1 | 6674.4 |
| Halflife, 16 in flight | 946.4 | 2521.4 | 4808.1 | 986.3 | 2733.5 | 5539.7 |

What this supports:

- **One request in flight: Halflife adds about 8–10 µs at the median, about 4% of a 215 µs mock round trip.** That cost includes capture, UUIDv7, queue submit and two headers. Against a real provider (hundreds of ms) it is under 0.01%.
- **p95 and p99 differences are inside the control's own spread.** The control's p99 moves by up to ±64 µs at 1 in flight. No tail overhead is claimed or ruled out at that resolution.
- **16 in flight: no measurable difference.** The control's p50 moves by ±200 µs and its p99 by several ms, which swamps anything Halflife does. We don't claim an overhead number at this concurrency.

Integrity, every run, every configuration:

- **2,000/2,000 pairs byte-identical**, 3 distinct bodies (one per prompt), 0 non-200 responses.
- From the Halflife gateway: `X-Halflife-Status: queued` on 2,000/2,000. From the gateway without it: 0.
- Shutdown totals: `halflife: stopped (enqueued=2200 dropped=0 audited=2200 failed=0 abandoned=0 queued=0)`. Every request, warm-up included, was captured and audited once, and none were dropped at 16 in flight with the default queue of 256.

### Correction during the task

The first version of the script ran all comparisons against one long-lived baseline gateway. At 16 in flight it reported Halflife 400–700 µs *faster*, which isn't credible. The baseline had served twice the traffic of the Halflife gateway and written twice as many rows to its log store. The fix: fresh gateways per comparison, plus the A/A control (D25). Those numbers were discarded and are not reported above.

## Task 16: Semantic cache baseline (2 Nov 2026)

**Status:** done. Command: `make cache` (`testenv/cache-baseline.sh`). This is Bifrost's own `semantic_cache` plugin, unmodified and without Halflife (D27). It runs on Docker `redis:8.2.2` (search module) with the mock provider and synthetic keys. No plugin code changed.

### Setup

- **Mock embeddings (D26).** `testenv/mockllm` gains `POST /v1/embeddings`, which takes a string or an array of strings, checks auth, counts calls per model, and fails on `fail-<status>` like chat does. `Embed` turns text into a deterministic 64-dim unit vector, a hashed bag of content words. 3 new unit tests pin the similarities the cache test relies on.
- **Config `testenv/configs/cache`.** The mock-llm config plus `vector_store: redis @ 127.0.0.1:6380`, and `semantic_cache` with `provider: openai`, `embedding_model: mock-embed`, `dimension: 64`, `ttl: 5m`, `threshold: 0.8`, `default_cache_key: halflife-smoke`. `mock-embed` is added to the key's models and both virtual keys' allowed models.
- **Fresh namespace per run.** `HalflifeCacheBaseline_<epoch>`, dropped afterwards. Redis is started if absent and stopped again; a Redis that was already running is left up.

### Lifecycle (34 checks, 6/6 runs)

| Step | Request | `x-bifrost-cache-*` | Provider `ok` calls | `mock-embed` calls | Store |
|---|---|---|---|---|---|
| 1 miss | "How much does the Acme Cloud Pro plan cost?" | `hit: false`, `id: <id>` | 1 | 1 | `<ns>:<id>` written (async, within 2 s): hash with `response`, `embedding`, `expires_at` (now + 300 s), `cache_key` |
| 2 direct hit | same | `hit: true`, `type: direct`, same id | 1 | 1 | same answer and response id |
| 3 semantic hit | "What does Acme Cloud Pro cost?" | `hit: true`, `type: semantic`, same id, `similarity: 0.926`, `threshold: 0.8` | 1 | 2 | the Pro-plan answer is served to the new wording |
| 4 unrelated miss | "Who is the CEO of Acme Cloud?" | `hit: false`, new id | 2 | 3 | own answer, new entry |
| 5 identity scope | step 1's question with the other virtual key | `hit: false` | 3 | 4 | 3 entries total |

Bifrost's request log (`logs.db`, `cache_debug` column) records each request with its virtual key:

```
vk-smoke 0 -
vk-smoke 1 direct
vk-smoke 1 semantic
vk-smoke 0 -
vk-verifier 0 -
```

### Observed, relevant to Halflife

1. **A semantic hit serves one question's answer to another question.** Step 3 returned the stored Pro-plan answer without asking the provider. If that answer is stale, the staleness reaches every paraphrase until the TTL runs out. This is the case freshness-aware caching (Tasks 17+) targets.
2. **Expiry is a field, not a Redis TTL.** Entries have no Redis expiry (`TTL` = -1); the plugin filters on `expires_at` at lookup.
3. **The cache key is stored hex-encoded** (`68616c666c6966652d736d6f6b65` = `halflife-smoke`). The Redis store encodes tag values (`framework/vectorstore/redis.go:1805`).
4. **Entries are scoped to the virtual key by default** (step 5), so one tenant's cached answer is never served to another.
5. **Embedding calls for the cache are not separate rows in the request log.** Their use shows up in the chat row's `cache_debug` (`provider_used`, `model_used`, `input_tokens`).

### Script fix carried over from Task 15

While probing, port 9101 was still held by a mock provider left over from a Task 15 benchmark run. The cause: on macOS bash 3.2 with `set -u`, expanding an empty array is an error. `stop_gateways` empties its array, so the exit trap failed before it killed the mock. Later bench runs failed to bind their own mock and used the leftover one instead. It was the same binary and fixtures, so the Task 15 numbers stand, but it was a real leak.

- **Fix:** `${a[@]+"${a[@]}"}` in `bench-halflife.sh` and `smoke-mock-llm.sh`.
- **Guard:** all gateway test scripts now refuse to start if the gateway or mock port is already in use.
- **Re-checked:** `make test`, `make smoke` (3× ALL PASS) and `bench-halflife.sh 1000` (ALL PASS) re-run, and port 9101 is free afterwards. That bench re-run wrote 1,000-pair results; the committed 2,000-pair Task 15 files were restored.

## Task 17: Cache ↔ report linkage (2 Nov 2026)

**Status:** done. Fork commit `12b7583`. Commands: `make test` (plugin) and `make cache` (`cache-baseline.sh`, then `cache-halflife.sh`).

### Behaviour

- On a cache miss, Halflife reads `cache_id` from the cache's `cache_debug` and links that entry to the new report (in-memory LRU of 100k links, D28). The link is added before the capture is queued, and removed again if the queue is full.
- A direct or semantic hit on a linked entry from the same tenant gets the filling report: `X-Halflife-Report: <same id>`, `X-Halflife-Status: cached`, and no new audit.
- A hit with no link (after a restart, or a dropped report) or from another tenant is audited as a new answer. One tenant is never pointed at another tenant's report.

### Tests

- **Plugin (real core + real `semantic_cache`, chromem store, D29):** `stack_test.go` and `links_test.go`: hits resolve to the filling report, cross-tenant hits get their own report, unlinked hits start a report, dropped reports are unlinked, no cache means no links, LRU order. All pass with `-race -count=3`; package coverage 96.4%.
- **Harness limit:** the harness has no governance grant, so the cache's identity scoping is off there. Tenant isolation through the cache is proven on the gateway instead.
- **Gateway (`testenv/cache-halflife.sh`, 29/29, 3 runs):** miss → queued report; direct and semantic hits → same entry, same report, `cached`, resolved in the log; the other tenant misses (identity scope) and gets its own report, which its own hit reuses. Provider calls `{"mock-embed":4,"ok":3}`; pool `enqueued=3 audited=3`: one audit per answer, not per response.
- **Integrity:** the same sequence through the cache without Halflife gives the same provider calls, statuses, cache outcomes and bodies (timing fields zeroed).

### Notes

- The plugin now requires `semanticcache` v1.7.4, the version the gateway already uses; the gateway's `go.mod`/`go.sum` are unchanged.
- `testenv/lib.sh` holds the shared start/stop/check helpers for the cache scripts. `vk-other` was added to the cache configs as a real second tenant (the verifier key had been standing in, and is correctly never audited).

## Task 18: TTL override (3 Nov 2026)

**Status:** done. Fork commit `92454da`. Commands: `make test` and `make cache`.

### Behaviour

- New config `cache_ttl_seconds` (0 = leave the cache's TTL; at most 30 days). In its PreLLMHook, Halflife sets `semantic_cache-ttl` to that value unless the request already asks for a shorter one (`x-bf-cache-ttl`), as D30 sets out. Halflife's PreLLMHook runs before every other plugin's hooks, and the cache reads the TTL in its PostLLMHook, before it spawns the async write. So the cap is in place when the entry is written.
- The init log line reports it (`cache_ttl=1m0s`, or `cache-default`).

### Tests

- **Plugin (real core + cache):** `ttl_test.go` reads `expires_at` from every entry that reaches the store. It covers six cases: no cap (cache 1m), cap below, cap above, longer client TTL capped, shorter client TTL kept, and client TTL with the cap disabled. A second test confirms that an entry written with a 1 s cap is served before expiry and misses afterwards. All pass with `-race -count=3`.
- **Gateway (`cache-halflife.sh`, 36/36, 3 runs):** `halflife-cache` sets `cache_ttl_seconds: 60`.

  | Request | Entry expires in |
  |---|---|
  | Without Halflife (cache TTL 5m) | ~300 s |
  | With Halflife | ~60 s |
  | `x-bf-cache-ttl: 1h` | ~60 s (capped) |
  | `x-bf-cache-ttl: 20` | ~20 s (kept) |

  Redis key `TTL` is -1 in every case: the cache expires entries by the `expires_at` field, not by Redis expiry. Integrity checks (bodies, provider calls) are unchanged.
- **Caught while writing it:** the first client-TTL question ("When was Acme Cloud founded?") was a semantic hit on the CEO entry, so the 1h check passed by reading the wrong entry. The questions now share no content words with the others, and a check asserts that both are misses with their own entries.

## Task 19: Invalidation and race (3 Nov 2026)

**Status:** done at plugin level, on Bifrost's real core and real `semantic_cache` plugin. Fork commit `fb5b14c`. A gateway-level check needs a stale verdict, which only the verifier (Tasks 21+) produces. It is deferred to then, not faked with a debug trigger.

### Behaviour

- The audit is now `verify` then, if stale, `invalidate`. Until the verifier exists, `verify` is a placeholder that finds nothing stale, so nothing is evicted in normal runs.
- `invalidate` removes the cache link (hits stop resolving to the stale report) and deletes the entry by `cache_id`. The gateway wires the delete to the `semantic_cache` plugin's own `ClearCacheForCacheID`, looked up at eviction time (`plugins.go`, see `UPSTREAM_DIFF.md`).
- **The race (D31).** The cache writes asynchronously, for up to 30 s after the response. If the audit finishes inside `cache_write_settle_seconds` (default 35) of the response, these steps run in order:
  1. Halflife first marks the answer's cache partition (`x-bf-cache-key`, or the default key) as bypassed.
  2. It deletes the entry.
  3. Once the window closes, it deletes again.
  4. It lifts the bypass only after that second delete succeeds.
  
  Bypassed requests carry a cache type the cache does not know, so it skips lookup, write and embedding. A delete that fails is retried every second with the bypass held. Shutdown stops pending deletes without waiting out the window.
- Stats gain `Invalidated` and `BypassedRequests`.

### Tests (`invalidate_test.go`; plugin coverage 95.6%)

| Test | What it proves |
|---|---|
| `TestStaleAnswerFoundBeforeCacheWrite` | Deterministic: the cache's write is held at a gate, verification returns stale, the first delete runs (finds nothing), then the gate opens and the stale write lands in the store. In the window: 2 repeats, a semantic paraphrase and 16 concurrent requests all get fresh provider answers (19/19 provider calls, 19 bypassed), never the stale one. A request in another partition still uses the cache. After the window: exactly 2 deletes, the next request is a miss, and a further 16 concurrent requests never get the stale answer. |
| `TestStaleAnswerAfterCacheWrite` | After the write settled: one delete, no bypass, and the stale answer is never served again. |
| `TestFailedEvictionKeepsBypass` | 3 failed deletes: the stale answer is not served while retrying; the bypass lifts after success. |
| `TestNoEvictionWithoutStaleOrEvictor` | Fresh answers stay cached; with no evictor a stale verdict is only logged. |
| `TestCleanupStopsPendingEvictions` | Shutdown does not wait out a 1 h window. |

Runs: `-race -count=5` and `-count=20` (no race detector), all pass.

### Found while testing

- **chromem-go data race (test store only).** chromem-go v0.7.0 reads its document map in `Delete` without the lock its `Add` takes, so a delete racing a write is a data race inside the in-process store. The harness serializes writes and deletes. Redis, the store the gateway uses, is not affected.
- **Timing assumption in a test.** Without the race detector the "after write" test ran inside its own 1 ms window and took the bypass path. It now waits the window out explicitly.
- **Task 18 regression in `smoke-halflife.sh`.** The startup log line gained `cache_ttl=…` in Task 18, and the smoke check still expected the old line. `make smoke` wasn't run for Task 18. It is fixed here; `make smoke` and `make cache` (2 runs each) all pass with the Task 19 gateway.

## Task 20: Tavily relay contract (3 Nov 2026)

**Status:** done. Fork commit `936899a`. Command: `make relay` (`testenv/relay-tavily.sh`): real gateway, mock Tavily on 9102, config `testenv/configs/relay`. No real Tavily call was made.

### Relay configuration (D32)

```json
{"name": "tavily", "base_url": "http://127.0.0.1:9102", "auth": {"type": "bearer"}, "credential": {"value": "tvly-mock"},
 "usage": {"units_path": "usage.credits", "cost_per_unit": 0.008},
 "routes": [{"method": "POST", "path": "/search"}, {"method": "POST", "path": "/extract"},
            {"method": "GET", "path": "/usage", "billable": false}]}
```

The verifier key `vk-verifier` holds the relay grant (`relay_grants: [{"relay_name": "tavily"}]`); `vk-smoke` holds none. $0.008 per credit is Tavily's pay-as-you-go price (docs.tavily.com/documentation/api-credits, read 3 Nov 2026). The live config (Task 21) changes `base_url` and takes the credential from the environment.

### Halflife's Tavily client (`plugins/halflife/tavily.go`)

- Posts to `{gateway}/relay/{tavily_relay}/search` or `/extract` with the verifier's virtual key. It never sends a Tavily credential: the relay injects it.
- Always sends `include_usage: true` and an explicit `search_depth` (`basic` by default); never sends `auto_parameters`.
- Sends `X-Project-ID` = tenant and `X-Session-Id` = report (D13), omitted when empty.
- Errors are `TavilyError{Status, Message, RetryAfter}`, with `Retryable()` (429, 434, 5xx) and `OutOfCredits()` (432, 433). It reads both Tavily's `{"detail":{"error"}}` and the gateway's `{"error":{"message"}}` shapes. Replies are capped at 4 MiB.
- Unit tests check the request shape, decoding and 8 error cases against a fake relay. `TestTavilyRelayContract` runs the same client against the real relay; the script sets its environment, and it is skipped otherwise.

### Gateway results (23 checks, 3 runs)

| Side | Observed |
|---|---|
| What reaches Tavily | The caller's `Authorization: Bearer caller-secret` is replaced by the relay credential (the mock accepts only `tvly-mock`). `x-bf-vk` and the caller's `X-Api-Key` are stripped. `X-Project-ID` and `X-Session-Id` are forwarded. |
| What the caller gets | Tavily's body unchanged. Advanced search reports 2 credits. Extract of 5 good URLs and 1 failing URL returns 5 results, 1 failure and 1 credit. 432 and its message pass through. 429 keeps `Retry-After: 2`. Replies carry `X-Bifrost-Request-Id` and no `X-Halflife-Status`. |
| What the gateway enforces | Key without a grant: 403. No key: 401. `POST /crawl` (not in the contract): 404. None of these reached Tavily. |
| What Bifrost charges | One relay-log row per call: `cost = units × 0.008` (1 credit $0.008, 2 credits $0.016). 432, 429, 401, 403 and `/usage` carry no cost. Refused routes and unknown relays are not in the relay log. The log holds no credential: no virtual key, Tavily key or caller secret appears anywhere in `logs.db`. |

**Measured gap.** A search sent without `include_usage` is billed by Tavily (1 credit; mock `/usage` counted it) but charged $0 by Bifrost, which has no `usage.credits` to read. Over the run Bifrost charged $0.064 (8 credits) while Tavily counted 9. Halflife's client always sends `include_usage`; anything else calling the relay would under-report. Reconciliation against Tavily's `/usage` (Task 38) is what catches it.

### Fixed along the way (D33)

Halflife set `X-Halflife-Status` on every route that runs the transport hooks. Relay replies said `not-audited; reason=failed`, `GET /v1/models` said `reason=verifier`, and `/mcp` said `reason=streaming`. Halflife now creates a slot only for POSTs outside `/relay/`, `/mcp` and `/api/`. `TestStatusHeaderOnlyOnInferenceRoutes` pins 9 routes; rejected chat requests keep `reason=failed`, as the smoke test checks. `make smoke` and `make cache` pass with the new gateway.

### Mock Tavily additions

`GET /usage` (free) and `last` in `/_mock/requests`: path, attribution headers, `include_usage`, and whether `x-bf-vk` or `X-Api-Key` reached it. Values of credentials are never recorded.

## Task 21: Live Tavily validation (3 Nov 2026)

**Status:** done. **Live:** real Tavily (`api.tavily.com`) through Bifrost's relay, with the real key from `.env`. Command: `testenv/live-tavily.sh`, run once. Config `testenv/configs/relay-live` is the Task 20 relay with `base_url: https://api.tavily.com` and `credential: env.TAVILY_API_KEY`, plus a relay `tavily-badkey` with a deliberately invalid key. Record: `testenv/results/tavily-live.json`.

### Spend controls

- At most 10 searches (the script refuses an eleventh); 8 were made, plus 1 single-URL Extract and free `/usage` reads.
- Reported: 7 credits. Bifrost charged $0.056 (7 × $0.008).
- `DRY_RUN=1` runs the same calls against mock Tavily; it was run first, to check the script without spending.

### Results

| Call | Status | `usage.credits` | Tavily `response_time` | Gateway latency (upstream) | Results |
|---|---|---|---|---|---|
| basic, `max_results: 3` | 200 | 1 | 1.49 s | 1743 ms (1742) | 3 (go.dev ×2, flaviocopes.com) |
| same query again | 200 | 1 | 0.0 s | 294 ms (293) | 3, identical: served from Tavily's cache, still billed |
| advanced | 200 | 2 | 2.82 s | 3075 ms (3074) | 3 |
| `max_age_hours: 24` | 200 | 1 | 2.55 s | 2802 ms (2802) | 3, different sources |
| `topic: news`, `time_range: week` | 200 | 1 | 1.22 s | 1511 ms (1488) | 3, all with `published_date` |
| without `include_usage` | 200 | (none) | 1.12 s | 1374 ms (1373) | 3; Bifrost charged $0 |
| `max_results: 50` | **200** | 1 | 2.22 s | 2948 ms (2947) | **50**; the spec's 0–20 limit is not enforced |
| invalid key (`tavily-badkey`) | 401 | (none) | n/a | 779 ms (778) | "Unauthorized: missing or invalid API key." |
| Extract, 1 URL | 200 | 0 | 0.02 s | 531 ms (528) | 1 page; Extract accrues per 5 URLs |

- **Gateway overhead** (relay log `overhead_latency`): 0.6–2.1 ms on 9 of 11 calls, 6.1 ms on the first call, 23 ms once.
- **`/usage`:** `plan_limit` 1000, and 0 used before the run, straight after it, and on three later reads up to 3 minutes after. Tavily's counter lags the calls (D35). Whether it ever counts the search sent without `include_usage` can only be read from a later `/usage`; until then it is unverified, and Bifrost's $0 for that call is the confirmed half of the gap.

### Redaction

- The script never reads the key: it only checks that `.env` has a non-empty `TAVILY_API_KEY`, and the gateway resolves `env.TAVILY_API_KEY` itself.
- The record keeps statuses, credits, timings, counts, top domains and error messages; it keeps no result text.
- Automated checks: no `tvly-` key-shaped string other than the two synthetic ones appears in the record or the gateway log, and the virtual key's value does not appear in the record.

### What changed because of it

- Mock Tavily accepts `max_results` above 20.
- Decisions D34 (no repeated searches within an audit) and D35 (late `/usage` reconciliation).
- Notes in `research/tavily-api-notes.md` → "Live observations".

## Task 22: Relay authorisation and budgets (3 Nov 2026)

**Status:** done. No fork change: governance already evaluates relay calls (`plugins/governance/relays.go`). Command: `make budget` (`testenv/relay-budget.sh`): real gateway, mock Tavily, config `testenv/configs/relay-budget` (the Task 20 relay config plus budgets). No real Tavily call. 18 checks, 3 runs, all pass.

### Configuration

| Key | Relay grant | Budget (1 h window) |
|---|---|---|
| `vk-verifier` | `tavily` | $0.02 |
| `vk-verifier-burst` | `tavily` | $0.02 |
| `vk-smoke` | none | $1 |

Budget usage is read from the gateway's `config.db` (`governance_budgets.current_usage`) after shutdown, which flushes it; the governance API needs dashboard auth.

### Results

| Check | Observed |
|---|---|
| Granted key | 200 |
| Key without the grant, with $1 left | 403 `relay_blocked`: the grant is checked, not just the money |
| No key | 401 |
| $0.02 budget, one call at a time | basic (spend 0 → 0.008) 200, basic (→ 0.016) 200, advanced (→ 0.032) 200, next basic **402 `budget_exceeded`** |
| Refused calls | Never reached Tavily (mock request count unchanged); no cost in the relay log |
| Free `GET /usage` after exhaustion | 402: every relay call is evaluated, billable or not |
| Another key's budget | Untouched; its call is 200 |
| Charges | `vk-verifier` budget = $0.032 = 4 credits Tavily reported × $0.008 = the key's relay-log cost |

Governance checks *spend so far* < limit before a call and charges after the reply (`CheckBudget`: `current_usage >= max_limit` refuses). So a budget is never refused early, and the call that crosses the limit is allowed: the overshoot is at most that one call's cost.

### Concurrency: budgets overshoot

10 concurrent searches on `vk-verifier-burst` ($0.02, $0.008 already spent), each held 500 ms by mock Tavily (new `[mock:slow-N]` marker; live searches took 1.1–2.8 s). One at a time, 2 would pass.

- All 10 passed, in 0.545–0.548 s of wall time (3 runs), so they really overlapped.
- The budget was charged all 11 calls: $0.088 on a $0.02 limit. The overshoot is charged, not lost, and the next call is refused.
- Nothing reserves spend for calls in flight. The overshoot is bounded by *concurrent calls × cost of one call*. Halflife bounds its own concurrency with `workers` (D36).

An earlier version of this check passed only 2 of 10. That was against a mock that answered in under 1 ms, so the "concurrent" calls ran one after another; the delay marker fixed the test, not the gateway.

## Task 23: Risk A, tenant attribution (3 Nov 2026)

**Status:** done; decision D37. Command: `make tenants` (`testenv/tenant-attribution.sh`): real gateway, mock Tavily, config `testenv/configs/tenants`. No real Tavily call. 16 checks, 3 runs, all pass. Record: `testenv/results/tenant-attribution.json`.

### Setup

Three tenants, each a governance customer with an app key: Acme (`cust-acme`, `vk-acme`), Globex, Initech. Two verifier layouts in the same gateway:

| Layout | Keys | Budgets |
|---|---|---|
| Shared | `vk-verifier`, no customer | $0.04 (5 searches) for everyone |
| Per-tenant | `vk-verifier-<tenant>`, inside the tenant's customer | $0.024 (3 searches) per key; customer budgets $1, except Initech $0.016 |

App keys have $1 each. Each verification is one basic search (1 credit, $0.008) tagged `X-Project-ID: vk-<tenant>`, as Halflife's client sends it.

### Results

| Measurement | Shared key | Per-tenant keys |
|---|---|---|
| Whose budget is charged | The shared key's only: $0.040 for 4 Acme + 1 Globex searches | The tenant's verifier key **and** its customer: Acme $0.024 / $0.024, Globex $0.016 / $0.016, Initech $0.016 / $0.016 |
| Tenant app keys | $0 | $0 |
| One tenant spends heavily (Acme) | Acme used the whole budget; then Globex and Initech were refused (402) for Acme's spend | Acme was refused after 3; Globex was unaffected (2 of 2 allowed) |
| Relay log | Every row `vk-verifier`, no customer, budget `budget-verifier`: Bifrost cannot tell the tenants apart | Every row names the tenant's customer and both budgets; cost by customer 0.024 / 0.016 / 0.016 |
| Tavily's own attribution (`X-Project-ID`) | Correct per tenant | Correct per tenant |

Credits Tavily (mock) attributed per `X-Project-ID` over both layouts: Acme 7, Globex 3, Initech 2, matching the allowed calls exactly; refused calls never reached it.

**Roll-up cost, measured.** Initech's customer budget ($0.016) was smaller than its verifier key's ($0.024). Its third verification was refused by the customer budget, and then **Initech's own chat request was refused too** (402, "customer Initech budget exceeded"), while Acme's and Globex's apps answered. A customer budget caps verification and app traffic together, so a verifier key's budget must leave the app its share of the customer's (D37).

Mock LLM answers cost $0 (their models are not in Bifrost's price catalog), so the customer budgets above hold verification spend only. With real models, app spend lands on the same customer budgets.

Mock Tavily now sums credits per `X-Project-ID` (`credits_by_project` in `/_mock/requests`), which is how Tavily-side attribution is measured above.

## Task 24: Minimal verifier (3 Nov 2026)

**Status:** done; decision D38. Fork commit `08e5596`. Plugin code: `claim.go`, `verifier.go`, config `verifiers`, `gateway_url`, `search_max_results`. Command: `make verify` (`testenv/verify-report.sh`, shared with Task 25): real gateway, mock LLM, mock Tavily, config `testenv/configs/verify`. No real Tavily or LLM call. 21 checks, 3 runs, all pass.

### What it does, per audited answer

1. **Picks one claim** (`pickClaim`): splits the answer into sentences (markdown list markers and emphasis removed), skips questions and fragments under 4 words, and scores each one: +2 per number, price, percent or year (up to 3), +2 for a temporal word ("latest", "current", "as of", …), +1 for a factual verb ("costs", "is", "released", …), −3 for hedging ("might", "I think", …), −1 for first- or second-person openings. It takes the best sentence scoring at least 2, or none.
2. **Builds a query** (`buildQuery`): the claim itself; if it opens with a pronoun ("It costs $49"), the question goes in front. Capped at 380 bytes.
3. **Chooses the key** (D37): the tenant's verifier key, else the `"*"` entry, else none: the report says `no_verifier_key` and nothing is spent.
4. **Searches once** through the relay: basic depth, 5 results, `include_usage`, `X-Project-ID` = tenant, `X-Session-Id` = report. The same tenant's same query within 10 minutes reuses the earlier result and spends nothing (D34). A retryable error (429, 434, 5xx) is retried once after `Retry-After` (at most 5 s); a 402 is recorded as `budget_exhausted` and not retried (D36).
5. **Stores the sources** on the report: title, URL, score, `published_date`, and a 500-byte snippet, with the credits charged and the relay call's gateway request ID.

It judges nothing: every report says `verdict: not_judged`, and no answer is found stale, so nothing is evicted from the cache yet.

The recursion guard now covers every verifier key in `verifiers` as well as `verifier_virtual_key`. A key value can be `env.VAR` (Bifrost's own `envutils.ProcessEnvValue`); if the variable is missing, `Init` fails and names the variable, not a value.

### Gateway results (with Task 25's endpoint)

| Case | Report |
|---|---|
| Acme: "How much does the Acme Cloud Pro plan cost?" → "The Acme Cloud Pro plan costs $20 per month and includes 100 GB of storage." | `evidence_found`; claim = that sentence; Acme's verifier key, 1 credit; sources `acme.example/pricing` (2026-10-01) and `news.example/acme-pro-price` (2026-09-15) |
| Same question again | New report; search reused, 0 credits, no new Tavily call |
| Acme, SDK version | `evidence_found` (`code.example/acme/acme-sdk/releases`) |
| Acme, third claim (CEO) | `budget_exhausted`: Acme's verifier key has a 2-search budget; the 402 is in the report's `error` |
| Globex, the price question | Its own key (`vk-verifier-globex`) and its own search: no reuse across tenants |
| Initech (no verifier key) | `no_verifier_key`, claim recorded, no search |
| "Tell me something nice" | `no_claim`, no search |

- Tavily (mock) received `X-Project-ID: vk-acme` and `X-Session-Id` = the report ID.
- The report's `gateway_request_id` matches a relay-log row on `vk-verifier-acme`, customer `cust-acme`, cost $0.008.
- Budgets after the run: Acme verifier key and Acme customer $0.016 each (2 searches), Globex verifier $0.008, Initech customer $0.
- 7 answers captured, 7 audited, 0 failed.

### Unit tests

`claim_test.go` (claim picking on 8 shapes, ties, length cap, queries), `verifier_test.go` (evidence, key choice and fallback, no claim, no evidence, 402, retry once and give up, reuse per tenant and expiry, a bounded memo, the real client over a fake relay, and the full plugin lifecycle through its hooks and pool), plus new config and `Init` cases. The plugin's suite passes under `-race`, 95.2% coverage.

### Fixtures

`fixtures/tavily.json` gained the three queries the verifier builds from the mock LLM's replies, mapped to the existing Acme evidence. The mock matches queries exactly, so without them every search got the generic default results.

### Scripts updated

`make smoke` (smoke and fallback) counted audits from the placeholder's log line, which is gone; they now count `halflife: report <id> complete`. The startup line gained `verifiers=` and `gateway=`. `make smoke` passes all three scripts (142 checks), and `make cache` (70), `make relay` (23), `make budget` (18) and `make tenants` (16) pass with the new gateway.

## Task 25: Report store and endpoint (3 Nov 2026)

**Status:** done; decision D39. Fork commits `08e5596` (store) and `d9bff71` (endpoint). Plugin: `report.go`; gateway: `handlers/halflife.go` and 9 lines in `server/server.go` (`UPSTREAM_DIFF.md`). Checked by `make verify` (above) and unit tests.

- **Lifecycle.** A report is stored as `queued` just before its answer is queued (so a fast worker always finds it), becomes `running`, then `complete` with an outcome and `completed_at`. If the queue is full, the report is removed together with the response's report header.
- **Content.** Request ID (linking to Bifrost's request and logs), tenant key ID and name, the answer (provider, model, fallback, question, text, cache entry), the claim and query, and the evidence. Key values never appear; the script and a unit test check for `sk-bf-` in every report.
- **Store.** In memory, the newest 10,000 (`report_store_size`), oldest evicted first; readers get deep copies. Reports do not survive a restart.
- **Endpoint.** `GET /api/halflife/reports/{id}` returns the report as JSON, 404 for an unknown or evicted ID, 400 if Halflife isn't loaded. It takes the same middlewares as every `/api` route, so it needs the same dashboard auth: without the setup token, 401.
- **Handler tests:** found, missing, plugin not loaded. The handlers package passes.


## Task 26: M1 end-to-end proof and decision (3 Nov 2026)

**Status:** done; decision D40, **GO**. Report: [M1_REPORT.md](M1_REPORT.md). Script `testenv/m1-proof.sh` (`make m1`), config `testenv/configs/m1`, records `testenv/results/m1-{mock,live}.json`. No fork change.

- **One run, in order:**
  - **A.** Startup log.
  - **E.** 20 calls on Acme's verifier key, 0 captures.
  - **B.** Acme's answer is queued, its report is served, completes after the response, is linked to the request and holds the served answer. A fallback request gives one report.
  - **D.** Acme's third claim is refused with 402 as `budget_exhausted`, and the spent key is refused for LLM calls too. Ungranted 403, keyless 401.
  - **F.** Globex uses its own key; Initech gets `no_verifier_key`.
  - **G.** Endpoint 401 / 404.
  - **Charges.** Each report has a relay-log row on the tenant's key and customer at credits × $0.008. Refused calls are uncharged. Budgets are read after shutdown. No key value appears in the record or the log.
- **Mock:** 22/22, 4 runs.
  - Mock Tavily gained `-search-delay` (held 1 s here) so the audit visibly completes after the response. With an instant mock the audit finished first and the check failed.
  - The guard runs before any search. The first run found that a spent verifier key's requests are refused with 402 (`reason=failed`) and don't reach the guard: 0 of 20.
- **Live, attempt 1:** OpenRouter returned 429 for `google/gemma-4-31b-it:free`.
  - The client got the 429 with `not-audited; reason=failed` and no report, which is correct. The rest of Acme's checks had nothing to check.
  - Fixed by sending Bifrost request fallbacks to `xingchen-agi/xing4.0-29b-a4b:free` and `openrouter/free`.
- **Live, attempt 2:** 22/22.
  - Acme was answered by the first fallback in 5.4 s; its report completed 3 s later. Globex was answered by `openrouter/free`.
  - 3 Tavily credits, $0.024 by Bifrost.
  - Budgets: Acme verifier $0.016/$0.016, Globex $0.008/$0.016, Initech $0.
- **Found:** the fallback model answered with its reasoning trace, and the keyword picker chose a hedged sentence from it ("…Go 1.24 might be out…"). Recorded as a Task 28 requirement, not fixed in M1.

## Task 27: Verifier LLM client (3 Nov 2026)

**Status:** done; decision D41. Fork commit `9f822eb`: `plugins/halflife/llm.go`, config fields `verifier_models`, `verifier_max_tokens` (default 1024), `verifier_reasoning_effort` (default unset), wired as `verifier.llmFor(tenant)`; nothing calls it yet (Task 28 does). Script `testenv/verifier-llm.sh` (`make llm`), records `testenv/results/verifier-llm-{mock,live}.json`.

- **Request.**
  - `POST <gateway_url>/v1/chat/completions` with the tenant's verifier key in `x-bf-vk`.
  - Body: the first model, the rest as Bifrost `fallbacks`, `temperature` 0, `max_tokens`, and `response_format` `{type: json_schema, json_schema: {name, strict: true, schema}}`. Optional `reasoning.effort`.
- **Reply.**
  - Content as a string or text parts; one Markdown fence is stripped and nothing else is repaired.
  - The reply is checked against the compiled schema (`santhosh-tekuri/jsonschema/v6 v6.0.2`, already the gateway's dependency; gateway `go.mod`/`go.sum` unchanged), then decoded.
  - The result records the model and provider that answered, whether a fallback answered, calls, malformed replies, truncation, tokens, and each call's `X-Bifrost-Request-Id`.
- **Failures.**

  | Case | Behaviour |
  |---|---|
  | Malformed (prose, wrong enum, missing or extra field, two objects, an array, empty, a refusal) | The reply and the schema error go back with one correction; a second failure is `ErrLLMMalformed` |
  | `finish_reason: length` and still invalid | `ErrLLMTruncated`, no retry |
  | 402 | Budget spent, never retried |
  | 400 / 401 / 403 / 404 | Not retried |
  | 429 / 5xx | Retried once after `Retry-After` (capped at 5 s) or 1 s |
  | Context cancelled during the wait | Stops |

- **Unit tests:** 16 new (`llm_test.go`) plus config cases; plugin coverage 95.2%, `-race` clean.
- **Through the gateway, mock** (`make llm`, all checks pass, 4 runs):
  - Models `openai/fail-500,openai/ok`: the first failed, and Bifrost's fallback answered with a schema-valid object in 1 call (`fallback: true`).
  - The mock provider received `response_format` as `json_schema:claim_check:strict`.
  - An unscripted prompt was malformed twice: 2 calls, no object.
  - After 2 relay searches spent Acme's verifier budget, the next LLM call got 402 (`vk_model_config * budget exceeded: 0.0160 >= 0.0160`): budget spent, 1 call.
  - None of the verifier's calls was captured for audit.
  - Every call is in Bifrost's request log on `vk-verifier-acme` / `cust-acme`.
- **Through the gateway, live** (free OpenRouter: `nvidia/nemotron-3.5-super-vl:free`, falling back to `xingchen-agi/xing4.0-29b-a4b:free` and `openrouter/free`; no Tavily call, $0). Three claim checks with given evidence: Go version (expect CONTRADICTED), OpenAI CEO (SUPPORTED), Acme price vs unrelated news (UNVERIFIABLE).

  | Run | Valid replies | Detail |
  |---|---|---|
  | 1, no effort, 512-token limit | 2 of 3 | Go case: empty content after 512 tokens of reasoning, twice (1024 tokens) |
  | 2, no effort, 1024-token limit, truncation detected | 2 of 3 | Go case: truncated at 1024 tokens, now in 1 call instead of 2 |
  | 3, `reasoning.effort: low` | 3 of 3 | Expected verdicts; Go case 791 tokens, 30 s. Quotes: verbatim for Go and CEO, empty for UNVERIFIABLE as asked. Go's quote, "It is the latest stable release.", is verbatim but doesn't name the version: a quote must decide the claim on its own (Task 33) |

  All runs: nemotron answered (no fallback needed), nothing was captured for audit, and every call was logged on Acme's verifier key and customer.
- **Not shown yet:** judgement quality on real Tavily evidence (Tasks 28–33), and verbatim-quote checking in code (Task 33). Three hand-written checks are a smoke test, not an evaluation.
