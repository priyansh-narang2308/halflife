# Progress

Task plan: [TASKS.md](TASKS.md). Evidence for each task: [VALIDATION.md](VALIDATION.md).

## Current state

- **Last completed:** Task 03 (Bifrost source at the pinned commit), 1 Nov 2026.
- **Next:** Task 04 (build and run unmodified Bifrost).

## Completed

| Task | Date | Summary |
|---|---|---|
| 01 | 2026-11-01 | Build window confirmed open; rules re-read; tools inventoried; Git repo initialised; 50-task plan written |
| 02 | 2026-11-01 | Go 1.27.3 fetched via the official toolchain mechanism; modules declaring `go 1.27.3` auto-switch and compile. `.env.example` added with every key the project needs |
| 03 | 2026-11-01 | Bifrost cloned at `e869c3f` and verified against GitHub's tag; `upstream` and `halflife` branches; reproducible via `scripts/bootstrap-bifrost.sh`; layout decided (D6); `UPSTREAM_DIFF.md` started |

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | One integrated project (Bifrost #04 + Tavily #01) | Rule 8 on the event page: "Each team may submit only one final project." |
| D2 | Build start = 1 Nov 2026 00:00 IST | The event page renders the round as "01 Nov 2026, 12:00 AM" and stores event times anchored to IST (event end `2026-11-29T18:29:00Z` = 23:59 IST). See VALIDATION.md, Task 01. |
| D3 | Treat existing `ANTHROPIC_API_KEY` as not ours to use | It is set together with `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`, which looks like the Claude Code session's own credential, not a project key. It will not be used unless you confirm it is a project key. |
| D4 | OpenRouter is the LLM provider, using free models for development and the demo | Bifrost v2.4.0 has a native `openrouter` provider (`core/schemas/bifrost.go:72`, `core/providers/openrouter/`). 14 free models listed on 1 Nov, 4 with structured outputs. Free cap: 20 req/min; 50 req/day below $10 of purchased credit, 1,000/day at ≥$10. The evaluation (Task 45) will need the higher cap or recorded replays. |
| D5 | Go toolchain via `GOTOOLCHAIN=auto`, not a system upgrade | Base install stays go1.25.1. Any module declaring `go 1.27.3` (as Bifrost's do) switches automatically to the checksum-verified go1.27.3 toolchain. |
| D6 | Repo layout: project repo `global-ai/` + Bifrost fork in `bifrost/` (its own Git repo, gitignored here). Our plugin will live at `bifrost/plugins/halflife/` as its own Go module | Mirrors upstream's one-module-per-plugin convention, so `make setup-workspace` picks it up and the work stays upstreamable. `git diff upstream..halflife` shows every change we make. For submission, the fork goes to your GitHub (needs your OK) and is linked here as a submodule, so one URL shows everything. |

## Blockers and inputs needed

| Item | Needed by | Status |
|---|---|---|
| `TAVILY_API_KEY` in `.env` | Task 21 (live validation) | Missing. Mock Tavily is used until then. |
| `OPENROUTER_API_KEY` in `.env` (optional 2nd provider for the fallback demo) | Tasks 26, 27, 42 | Missing. Mock provider is used until then. |
| Docker daemon running, or approval to use Homebrew Redis | Task 06 | Docker installed but not running; Redis 8.6.3 installed but not started |
| Go 1.27.3 | Task 02 | Resolved |

## Open assumptions

- The organizers have not stated the timezone in words; D2 rests on the page's own timestamps.
- Discord membership is mandatory (rule 3). Worth asking there: video requirement, and whether Bifrost and Tavily judge separately.
