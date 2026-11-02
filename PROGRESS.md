# Progress

Task plan: [TASKS.md](TASKS.md). Evidence for each task: [VALIDATION.md](VALIDATION.md).

## Current state

- **Last completed:** Task 05 (deterministic mock servers), 2 Nov 2026.
- **Next:** Task 06 (local infrastructure: Redis and one-command startup).

## Completed

| Task | Date | Summary |
|---|---|---|
| 01 | 2026-11-01 | Build window confirmed open; rules re-read; tools inventoried; Git repo initialised; 50-task plan written |
| 02 | 2026-11-01 | Go 1.27.3 fetched via the official toolchain mechanism; modules declaring `go 1.27.3` auto-switch and compile. `.env.example` added with every key the project needs |
| 03 | 2026-11-01 | Bifrost cloned at `e869c3f` and verified against GitHub's tag; `upstream` and `halflife` branches; reproducible via `scripts/bootstrap-bifrost.sh`; layout decided (D6); `UPSTREAM_DIFF.md` started |
| 04 | 2026-11-01 | Unmodified gateway + dashboard built from source (`scripts/build-gateway.sh`, reproducible SHA-256); runs and passes health, UI and shutdown checks via `scripts/run-gateway.sh`; compiled modules confirmed identical to the audited source |
| 05 | 2026-11-02 | Mock LLM provider and mock Tavily (`testenv/`), 15/15 unit tests under `-race`, ~90%+ coverage; real gateway → mock provider smoke test passes 12/12 checks, including streaming and a fallback with one attempt per model |

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | One integrated project (Bifrost #04 + Tavily #01) | Rule 8 on the event page: "Each team may submit only one final project." |
| D2 | Build start = 1 Nov 2026 00:00 IST | The event page renders the round as "01 Nov 2026, 12:00 AM" and stores event times anchored to IST (event end `2026-11-29T18:29:00Z` = 23:59 IST). See VALIDATION.md, Task 01. |
| D3 | Treat existing `ANTHROPIC_API_KEY` as not ours to use | It is set together with `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`, which looks like the Claude Code session's own credential, not a project key. It will not be used unless you confirm it is a project key. |
| D4 | OpenRouter is the LLM provider, using free models for development and the demo | Bifrost v2.4.0 has a native `openrouter` provider (`core/schemas/bifrost.go:72`, `core/providers/openrouter/`). 14 free models listed on 1 Nov, 4 with structured outputs. Free cap: 20 req/min; 50 req/day below $10 of purchased credit, 1,000/day at ≥$10. The evaluation (Task 45) will need the higher cap or recorded replays. |
| D5 | Go toolchain via `GOTOOLCHAIN=auto`, not a system upgrade | Base install stays go1.25.1. Any module declaring `go 1.27.3` (as Bifrost's do) switches automatically to the checksum-verified go1.27.3 toolchain. |
| D6 | Repo layout: project repo `global-ai/` + Bifrost fork in `bifrost/` (its own Git repo, gitignored here). Our plugin will live at `bifrost/plugins/halflife/` as its own Go module | Mirrors upstream's one-module-per-plugin convention, so `make setup-workspace` picks it up and the work stays upstreamable. `git diff upstream..halflife` shows every change we make. For submission, the fork goes to your GitHub (needs your OK) and is linked here as a submodule, so one URL shows everything. |
| D7 | The gateway always runs with a clean environment (`scripts/run-gateway.sh`) | Bifrost auto-imports `OPENAI_*`/`ANTHROPIC_*`/`MISTRAL_*` keys when there's no `config.json`; on the first run it picked up Claude Code's `ANTHROPIC_API_KEY`. |
| D8 | Gateway port 8090 | 8080 is taken on this machine by an Apache `httpd`. |
| D9 | Halflife's UI lives inside Bifrost's own dashboard (Task 47) | The dashboard builds from source here, so Halflife can appear as a native Bifrost page, which is a stronger story than a separate site. |
| D10 | Test configs list mock model names explicitly in both the virtual key and the provider key | `["*"]` only admits models in Bifrost's catalog; the mock's names aren't in it. Same rule will apply to OpenRouter free models. |
| D11 | Keep `enforce_auth_on_inference` on (its default); every test request carries a virtual key | Matches a real deployment, and per-app identity (virtual keys) is what Halflife attributes reports and spend to. |
| D12 | Tavily budget: 9,000 credits (Researcher plan + add-on), pay-as-you-go off | Spend stops at the cap with `432`, no billing. Plan: ~50 for live validation, ≤6,000 for evaluation, rest for demo/judging; every call sends `include_usage`. See `research/tavily-api-notes.md`. |
| D13 | Use Tavily's `max_age_hours` (content freshness, new in Oct 2026) as the core freshness lever, `X-Project-ID` = tenant and `X-Session-Id` = report for attribution inside Tavily | Directly matches Tavily #01 and gives tenant attribution that doesn't depend on Bifrost alone. Header forwarding through the relay is checked in Task 20. |

## Blockers and inputs needed

| Item | Needed by | Status |
|---|---|---|
| `TAVILY_API_KEY` in `.env` | Task 21 (live validation) | Account ready (9,000 credits); key not yet in `.env`. Mock Tavily is used until then. |
| `OPENROUTER_API_KEY` in `.env` (optional 2nd provider for the fallback demo) | Tasks 26, 27, 42 | Missing. Mock provider is used until then. |
| Docker daemon running, or approval to use Homebrew Redis | Task 06 | Docker installed but not running; Redis 8.6.3 installed but not started |
| Go 1.27.3 | Task 02 | Resolved |

## Open assumptions

- Upstream `ui/.npmrc` (`legacy-peer-deps=true`) skips a lockfile peer dependency and breaks a clean UI build. Worked around in `scripts/build-gateway.sh`; possibly worth reporting upstream.

- The organizers have not stated the timezone in words; D2 rests on the page's own timestamps.
- Discord membership is mandatory (rule 3). Worth asking there: video requirement, and whether Bifrost and Tavily judge separately.
