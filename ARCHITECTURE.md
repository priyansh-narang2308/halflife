# Architecture

Halflife is a Bifrost plugin, not a service beside it. It runs inside the gateway process, sees every answer the gateway serves, and does all its external work through Bifrost's own governance, so verification is budgeted, attributed and observable the same way application traffic is.

```
app ──► Bifrost ──► semantic cache ──► provider
          │  ▲
          │  └─ headers, cache eviction, TTL by volatility
          ▼
       Halflife capture (post-hook, non-blocking enqueue)
          │
          ▼  bounded queue, worker pool
       extract claims ─► classify and prioritise ─► search ─► judge ─► report
          │                                           │         │
          └── verifier LLM key ───────────────────────┼─────────┘
                    through the gateway               │
                                                      └─ Tavily, through a Bifrost relay
                                                         with the tenant's verifier key
```

## On the request path

The hooks copy what the audit needs and enqueue it. Nothing on the request path waits for verification (except in protect mode, on request). The added latency, paired against the same gateway without the plugin, has a median of +66.5 µs at concurrency 1 and +215.6 µs at concurrency 16 (`make bench`, mock upstream). If the queue is full the answer goes out unaudited and the drop is counted.

## The audit

| Step | File | What it does |
| --- | --- | --- |
| Capture | `capture.go` | Answer, tenant, model and cache identity; streams are not audited |
| Extract | `extract.go`, `scope.go` | Atomic claims with a verbatim span, category, temporal scope and volatility band, by structured output with a validated schema |
| Prioritise | `priority.go` | Deterministic rules decide what is worth paying to check: how soon facts of this kind change, against the time elapsed since the answer's information was current. Historical, timeless and future claims are skipped |
| Retrieve | `retrieval.go`, `tavily.go`, `untrusted.go` | Tavily search through the relay, one Extract on the best source when snippets fall short; page text is untrusted input and is fenced from the judge's instructions |
| Judge | `judge.go`, `compare.go`, `strength.go` | Verdicts: CURRENT, OUTDATED, CONTRADICTED, CONFLICTING, UNVERIFIABLE, NOT_CHECKED. A quote must exist verbatim in the evidence, or it does not count |
| Report | `report.go`, `store.go`, `list.go` | Persistent, retained for a bounded time, served at `/api/halflife` |
| Act | `invalidate.go`, `tombstone.go` | Evicts stale cache entries and keeps the question off the cache for a TTL so it is not re-served or re-audited |

## Modes

- `monitor`: observe only; no headers, no cache action.
- `audit` (default): off-path verification, TTL capped by volatility, stale answers evicted. The first user still gets the stale answer.
- `protect`: audit, plus synchronous verification for requests that ask for it, bounded by `protect_timeout_ms`; fails open.

## Cost and tenancy

Each tenant maps to its own verifier virtual key. Every search and judge call carries that key, so Bifrost's budgets, rate limits and logs apply per tenant, and one tenant running out does not affect another (`make tenants`, `make failures`). On top of the budget, a spend cap degrades in order: LOW claims need over 50% of the cap left, MEDIUM over 20%, HIGH needs the cost of one claim (`spend.go`).

## Failure handling

Tavily and the verifier LLM each sit behind a circuit breaker with honoured `Retry-After`, a credit-exhausted cooldown, and a budget backoff (`resilience.go`). A failed audit says why in the report; an answer is never held back because verification is unavailable. Fault injection is in `make failures`.

## Dashboard

`bifrost/ui/app/workspace/halflife/` adds a Halflife page to Bifrost's own dashboard: claims, verdicts, sources, spend per tenant and cache events, behind the Logs permission.

## Changes to upstream

Every change to Bifrost itself is listed, with its reason, in [UPSTREAM_DIFF.md](UPSTREAM_DIFF.md). Decisions are recorded in [PROGRESS.md](PROGRESS.md).
