# Progress

Task plan: [TASKS.md](TASKS.md). Evidence for each task: [VALIDATION.md](VALIDATION.md).

## Current state

- **Last completed:** Task 01 (pre-flight checks and Git workspace), 1 Nov 2026.
- **Next:** Task 02 (Go 1.27.3 toolchain).

## Completed

| Task | Date | Summary |
|---|---|---|
| 01 | 2026-11-01 | Build window confirmed open; rules re-read; tools inventoried; Git repo initialised; 50-task plan written |

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | One integrated project (Bifrost #04 + Tavily #01) | Rule 8 on the event page: "Each team may submit only one final project." |
| D2 | Build start = 1 Nov 2026 00:00 IST | The event page renders the round as "01 Nov 2026, 12:00 AM" and stores event times anchored to IST (event end `2026-11-29T18:29:00Z` = 23:59 IST). See VALIDATION.md, Task 01. |
| D3 | Treat existing `ANTHROPIC_API_KEY` as not ours to use | It is set together with `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`, which looks like the Claude Code session's own credential, not a project key. It will not be used unless you confirm it is a project key. |

## Blockers and inputs needed

| Item | Needed by | Status |
|---|---|---|
| `TAVILY_API_KEY` in the environment | Task 21 (live validation) | Missing. Mock Tavily is used until then. |
| ≥1 LLM provider key (≥2 for the fallback demo) | Tasks 27, 42 | Missing. Mock provider is used until then. |
| Docker daemon running, or approval to use Homebrew Redis | Task 06 | Docker installed but not running; Redis 8.6.3 installed but not started |
| Go 1.27.3 | Task 02 | Installed: go1.25.1; cached toolchains up to 1.27.1 |

## Open assumptions

- The organizers have not stated the timezone in words; D2 rests on the page's own timestamps.
- Discord membership is mandatory (rule 3). Worth asking there: video requirement, and whether Bifrost and Tavily judge separately.
