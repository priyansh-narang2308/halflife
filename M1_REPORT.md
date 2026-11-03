# M1 report: end-to-end proof and decision

3 Nov 2026. Task 26. Measured against the M1 exit criteria in [research/phase2-engineering-audit.md](research/phase2-engineering-audit.md) §7–8.

**Decision: GO.** The plugin path is proven on the real gateway: request → Bifrost → capture → Tavily through the relay → report. Spend is attributed and capped per tenant. A live run passed on real providers. What M1 does not prove, and still has to be built and measured, is listed under H.

## How to reproduce

| Command | What runs | Cost |
|---|---|---|
| `make m1` | `testenv/m1-proof.sh` against the mock LLM and mock Tavily (held 1 s per search) | none |
| `LIVE=1 make m1` | The same script. Acme's and Globex's first questions go to a free OpenRouter model, and every search goes to `api.tavily.com` | at most 4 Tavily credits (capped by the verifier budgets); OpenRouter free models are $0 |

Each run writes `testenv/results/m1-{mock,live}.json`. Keys are synthetic; the record holds no credential and no page text, only source URLs, titles and dates. The script fails if a Tavily, OpenRouter or virtual-key value appears in the record or the gateway log.

| Run | Result |
|---|---|
| Mock | 22/22 checks, 4 runs in a row |
| Live, first attempt | Failed: OpenRouter returned 429 for `google/gemma-4-31b-it:free`. Halflife passed the 429 through, marked the call `not-audited; reason=failed` and opened no report, which is correct. The test had nothing to check, so the script now sends Bifrost request fallbacks across two more free models |
| Live, second attempt | 22/22. 3 Tavily credits, $0.024 charged by Bifrost |

## A. Build and registration (M1-A): pass

- The Bifrost v2.4.0 fork builds with Go 1.27.3, using `GOWORK=off` and the published modules (Tasks 02–04, 08).
- Halflife is registered in-tree as a built-in: 3 upstream files, +24 lines. The report endpoint adds 9 lines in `server/server.go`. Both are listed in [UPSTREAM_DIFF.md](UPSTREAM_DIFF.md).
- The startup log shows Halflife loaded with 2 tenant verifier keys. The proof checks this line in both modes.

## B. Capture, header, async, fallback (M1-B): pass

- **Capture.** Acme's answer came back as an ordinary chat completion with `X-Halflife-Report: hlr_…` and `X-Halflife-Status: queued`.
- **Report.** The report is linked to the request's `X-Bifrost-Request-Id` and holds the answer the client received.
- **Timing.** Live: the answer arrived in 5.4 s (with model fallbacks) and the report completed 3 s later. Mock: the answer arrived in under 3 ms and the report completed 1 s later. In both runs the report's `completed_at` falls after the client had its full response. Halflife's own cost on the request path is 7.8–9.6 µs at the median, from `make bench` (Task 15).
- **Fallbacks.** A request whose first model failed (`openai/fail-500` → `openai/ok`) produced one report, of the answer that was served (Task 13: 71/71 across 6 scenarios × 2 retry settings).

## C. Cache lifecycle (M1-C): pass, from earlier tasks

Not re-run in the M1 script, because it needs Redis. `make cache` covers it (Tasks 16–19):

- A miss links its `cache_id` to its report.
- Hits are served that report and are not re-audited.
- Halflife's TTL cap is visible in the entry's `expires_at`.
- Evicting by ID uses the cache's own `ClearCacheForCacheID`.
- A stale finding inside the cache's write window bypasses that cache partition (D31).

M1 marks nothing stale (D38). Eviction is wired and tested, and stays off in production paths until the judge exists.

## D. Tavily through the relay (M1-D): pass

- **Pricing.** Every report's search is in Bifrost's relay log, on the tenant's verifier key and customer, at `usage.credits` × $0.008. Live: 3 searches, 3 credits, $0.024.
- **Budgets.** Acme's verifier budget is 2 searches ($0.016). Acme's third claim was refused with 402, recorded as `budget_exhausted` and not retried.
- **One budget per verifier key.** The spent key was then refused for an ordinary LLM call too: one budget covers both its searches and its LLM calls. The judge (Task 27) must therefore treat a 402 on its own LLM call the same way: not verified, budget spent.
- **Access.** Acme's app key, which has no relay grant, gets 403. A keyless call gets 401. Refused calls are never charged.
- **Earlier evidence.**
  - Task 21: 8 live searches and 1 Extract; the credit field is present.
  - Task 22: grants and budgets, including the soft overshoot under concurrency (D36).

## E. Recursion guard (M1-E): pass

- 20 requests went through on Acme's verifier key. All 20 were answered, marked `not-audited; reason=verifier`, and produced no report and no capture.
- The guard runs first in the script, while that key still has budget. On a spent key the requests are refused with 402 and labelled `reason=failed`, so they would not test the guard (the first mock run found this: 0 of 20).

## F. Tenant attribution (Risk A): pass

- Globex's question was searched with Globex's own verifier key and charged to Globex's key and customer budgets. Acme's spend never touched Globex's budgets.
- Initech has no verifier key: its claim was recorded as `no_verifier_key` and nothing was spent.
- Live budgets after the run:

| Budget | Usage |
|---|---|
| Acme verifier | $0.016 of $0.016 |
| Acme customer | $0.016 |
| Globex verifier | $0.008 of $0.016 |
| Globex customer | $0.008 |
| Initech | $0 |

The design comes from Task 23 (D37): one verifier key per tenant, inside the tenant's customer, with a budget below the customer's.

## G. Report and endpoint: pass

- `GET /api/halflife/reports/{id}` serves the report behind the gateway's dashboard auth: 401 without the setup token, 404 for an unknown ID.
- Each report holds the claim, the query, the verifier key ID, credits, the relay's gateway request ID, Tavily's request ID, and the sources. No key value is stored.
- Live example (Globex):
  - The free model answered "Sam Altman is the current CEO of OpenAI."
  - Halflife searched that sentence and stored 5 sources, including Wikipedia, Britannica and openai.com.
  - The report says `evidence_found`, `verdict: not_judged`.

## H. Risks found, and the decision

**What M1 does not show.**

- **No verdicts yet.** No answer has been judged CURRENT or OUTDATED. Reports say `not_judged`. Tasks 27–34 build the judge.
- **The keyword claim picker is not good enough.** Live, gemma was rate-limited and the fallback model (`xingchen-agi/xing4.0-29b-a4b:free`) answered with its reasoning trace. The picker chose "As of November 2024, Go 1.24 might be out, but let's stick to my latest known knowledge…": a hedged sentence that scored high on numbers and dates despite the hedge penalty. Tavily returned relevant Go release pages anyway, but the claim was the wrong one. Task 28 must:
  - extract atomic claims with verbatim spans;
  - drop reasoning text and hedges before any search.
- **Free models are unreliable upstreams.** The first live attempt got a 429. The verifier's own LLM calls (Task 27) need model fallbacks and must record a refused or rate-limited judge call as "not verified", never as a verdict.
- **Budgets are soft.** Concurrent calls can overshoot a budget by up to `workers` × the costliest call (D36).
- **Reports are in memory.** They are lost on restart (Task 35).
- **Streams aren't audited** (Task 14).

**Against the audit's conditions (§8).**

- **Condition 1, partly late.** M1-A, B and E passed on 2 Nov. M1-D passed on 3 Nov: one day late against condition 1's 2 Nov date, without consequence, because nothing in the pivot rule's trigger (A or B failing) happened.
- **Condition 2, met.** M1-C passed on 3 Nov.
- **Condition 3 still applies.** No pre-registered claim is made yet.

**Decision: GO.** The earlier "conditional" rested on gateway capabilities proven only by reading source. Every one of them has now been run on the real gateway, mock and live. The differentiation is real, measured Bifrost depth:

- in-path capture with fallback-aware auditing;
- governed, priced, per-tenant Tavily spend;
- a recursion guard;
- cache linkage and eviction.

The remaining risk is verification quality, which is the work of Milestone 2 and will be measured on held-out data before any accuracy claim is made.
