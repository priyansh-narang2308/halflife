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
