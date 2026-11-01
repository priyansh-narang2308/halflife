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
