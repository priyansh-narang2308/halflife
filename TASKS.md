# Halflife — Task Plan

One task per review cycle: I finish a task, record evidence in `VALIDATION.md` and `PROGRESS.md`, commit, and stop. You review and say "continue".

**Project:** Halflife is a Bifrost gateway plugin. It audits completed LLM answers for claims that have gone stale, re-verifies them with Tavily through Bifrost's governed relays, and makes the gateway's semantic cache freshness-aware.
**Tracks:** Bifrost #04 (missing gateway feature) + Tavily #01 (stale-answer detector), as one integrated project.
**Pinned upstream:** `maximhq/bifrost` tag `transports/v2.4.0`, commit `e869c3f9adc96ea53c38694a21bb04a8e1085487`.
**Build window:** 1 Nov 2026 00:00 IST to 15 Nov 2026 23:59 IST.

Status: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked.
"Needs" lists inputs only you can provide.

## Phase 0: Foundation

| # | Task | Done when | Needs |
|---|---|---|---|
| [x] 01 | Pre-flight checks and Git workspace | Window, rules, tools and key presence recorded; repo initialised; this plan committed | — |
| [ ] 02 | Go 1.27.3 toolchain | `go version` reports go1.27.3 inside the Bifrost module; reproducible via `GOTOOLCHAIN` | — |
| [ ] 03 | Bifrost source at the pinned commit | Fork checked out at `e869c3f`, commit verified, `upstream` and `halflife` branches, layout decided and documented | — |
| [ ] 04 | Build and run unmodified Bifrost | Gateway binary builds from source; starts; health check passes; build log saved | — |
| [ ] 05 | Deterministic mock servers | Mock OpenAI-compatible provider (scripted replies, injected failures, latency, streaming) and mock Tavily (recorded fixtures, error codes 401/429/432/433/434); unit tests pass | — |
| [ ] 06 | Local infrastructure | Redis running (Docker or Homebrew); `make` / script targets to start gateway, mocks and Redis in one command | Start Docker Desktop, or OK to use Homebrew Redis |

## Milestone 1-A: Bifrost extension

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 07 | Halflife plugin skeleton | Go module with `Init`, `GetName`, `Cleanup`, LLM and HTTP transport hooks (no-ops); config struct; unit tests pass | — |
| [ ] 08 | In-tree registration | Plugin registered in `transports/bifrost-http/server/plugins.go` with placement and order; minimal upstream diff; gateway builds | — |
| [ ] 09 | Plugin load smoke test | Gateway starts with Halflife enabled; startup log names it; requests pass through unchanged; `UPSTREAM_DIFF.md` v1 | — |

## Milestone 1-B: Response capture

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 10 | Final-response capture | Successful attempt stashed in `PostLLMHook`, finalised once in `HTTPTransportPostHook`; data copied out of pooled objects | — |
| [ ] 11 | Report identity | Report ID generated; `x-halflife-report` header set in `HTTPTransportResponseHeadersHook`; request ID, virtual key, model recorded | — |
| [ ] 12 | Bounded worker pool | Fixed-size queue and workers, background contexts, saturation → drop and count, graceful drain on `Cleanup` | — |
| [ ] 13 | Fallback correctness | Primary fails then fallback succeeds → exactly 1 audit; all attempts fail → 0 audits (mock provider) | — |
| [ ] 14 | Recursion guard and streaming | Verifier-key traffic is never audited; streaming requests detected and explicitly marked "not audited in M1" | — |
| [ ] 15 | Overhead and integrity | Plugin on/off latency benchmark (p50/p95/p99, N≥1,000); response bodies byte-identical with and without the plugin | — |

## Milestone 1-C: Cache correctness

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 16 | Semantic cache baseline | Built-in semantic cache on Redis; miss → write → hit observed and logged | Task 06 |
| [ ] 17 | Cache ↔ report linkage | `cache_id` captured on miss; cache hits resolve to the report of the response that filled the cache | — |
| [ ] 18 | TTL override | Halflife sets the cache TTL before the cache's async write; Redis TTL confirmed | — |
| [ ] 19 | Invalidation and race | Evict by `cache_id`; deterministic test where verification finishes before the cache write; repeated and concurrent requests after invalidation never return the stale entry | — |

## Milestone 1-D: Tavily through Bifrost (+ Risk A)

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 20 | Tavily relay contract | Relay configured for Search (and Extract); `include_usage`; `units_path: usage.credits`; contract tests against mock Tavily pass | — |
| [ ] 21 | Live Tavily validation | ≤10 controlled live Search calls; actual `usage.credits` fields, latency and errors recorded (redacted) | `TAVILY_API_KEY` |
| [ ] 22 | Relay authorisation and budgets | Granted key → 200; ungranted key → denied; tiny budget → refused once exhausted; charges = credits × configured rate | — |
| [ ] 23 | Risk A: tenant attribution | 3 tenants with distinct keys and budgets; measured which budget each verification charges (shared vs per-tenant verifier key); decision recorded | — |

## Milestone 1-E: End-to-end proof

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 24 | Minimal verifier | Worker picks one factual claim (simple heuristic), builds a query, calls Tavily via the relay, stores sources | — |
| [ ] 25 | Report store and endpoint | In-memory/SQLite store; in-tree handler `GET /api/halflife/reports/{id}`; report linked to the gateway request | — |
| [ ] 26 | M1 end-to-end proof and decision | One script: request → Bifrost → capture → Tavily → report; M1 report (sections A–H) with GO / CONDITIONAL GO / PIVOT | LLM key optional |

## Milestone 2: Verification engine

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 27 | Verifier LLM client | Calls go through Bifrost with the verifier key; structured JSON output with schema validation and retries | ≥1 LLM key |
| [ ] 28 | Atomic claim extraction | Claims with verbatim source spans; span check rejects paraphrase drift; unit tests on fixtures | — |
| [ ] 29 | Temporal scope classifier | CURRENT / HISTORICAL / TIMELESS / FUTURE / UNCLEAR; historical claims skipped | — |
| [ ] 30 | Volatility and priority | 5 volatility bands (from RecencyQA's scale); knowledge-cutoff table; HIGH / MEDIUM / LOW / SKIP priority | — |
| [ ] 31 | Retrieval policies | Per-category Tavily parameters (topic, time range, `max_age_hours`, preferred domains, Extract when snippets are thin) | — |
| [ ] 32 | Typed comparators | Deterministic semver, price, name and date comparison with tests | — |
| [ ] 33 | Evidence-backed verdicts | CURRENT / OUTDATED / CONTRADICTED / CONFLICTING / UNVERIFIABLE; OUTDATED requires proof it was once true; quotes verified verbatim | — |
| [ ] 34 | Evidence strength and freshness score | STRONG / MODERATE / WEAK; 0–100 freshness score labelled heuristic | — |

## Milestone 3: Reliability and reporting

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 35 | Persistent reports | SQLite store with claim-level provenance, retention limit, migrations | — |
| [ ] 36 | Untrusted web content | Injection defences, size caps, sanitisation; adversarial fixtures pass | — |
| [ ] 37 | Failure handling | Tavily 429 (Retry-After), 432/433/434, timeouts, circuit breaker; budget-aware degradation; failure-injection tests | — |
| [ ] 38 | Operator attribution and metrics | Per-key audits, verdicts, credits and USD; metrics endpoint | — |
| [ ] 39 | Audit / Protect / Monitor modes | Config-selectable modes with documented behaviour and tests | — |

## Milestone 4: Differentiation

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 40 | Adaptive verification budget | Per-tenant spend cap drives claim selection; behaviour tested | — |
| [ ] 41 | Freshness-aware cache | TTL from volatility; evict on OUTDATED; tombstones; deterministic tests | — |
| [ ] 42 | Fallback and spend experiments | Provider-fallback demo; measured spend and reliability runs | — |

## Milestone 5: Evaluation

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 43 | HL-Claims dataset | Claims mined from FreshQA snapshot diffs, RecencyQA and curated sources; labelled; dev/test split frozen before tuning | Your labelling review |
| [ ] 44 | Baselines and replay harness | Systems S0–S4 runnable; recorded-response replay makes runs reproducible | — |
| [ ] 45 | Run the evaluation | Precision, recall, F1, cost, latency, cache effectiveness, failure injection on the held-out set | Keys, credit budget |
| [ ] 46 | Evaluation write-up | `EVALUATION.md` with methods, numbers and limitations; nothing unmeasured is claimed | — |

## Milestone 6: Presentation and submission

| # | Task | Done when | Needs |
|---|---|---|---|
| [ ] 47 | Developer dashboard | Report viewer with claims, verdicts, sources, spend and cache events | — |
| [ ] 48 | Deployment | Docker Compose stack plus a hosted demo | Hosting choice |
| [ ] 49 | Docs and demo video | README, ARCHITECTURE, sponsor explanations; recorded before/after demo | You record or approve |
| [ ] 50 | Submission | Checklist complete, AI-use disclosure, submitted on HackCulture before 15 Nov 23:59 IST | You submit |
