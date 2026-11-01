# Halflife: Phase 2 Engineering Audit

Audit date: 31 Oct to 1 Nov 2026. This continues `research/hackathon-strategy-report.md`.
No competition code has been written.

## What was actually inspected

| Source | How | Revision |
|---|---|---|
| maximhq/bifrost | Sparse clone at tag `transports/v2.4.0`. Source read with grep and sed | commit `e869c3f9adc96ea53c38694a21bb04a8e1085487` (29 Oct 2026) |
| Vbj1808/dokis | Full clone. Source, tests, benchmark output | `6738628` (28 Apr 2026) |
| advaithsarva/fact-checking-agent | Full clone. Source, tests, RESULTS.md | `a449966` (17 Sep 2026) |
| aic-factcheck/facticli | Full clone. Source, prompts, eval code | `3ce836a` (5 Oct 2026) |
| DataScienceUIBK/RecencyQA | Full clone. Dataset statistics computed locally, prompts read | `21b0c3b` (23 Oct 2026) |
| freshllms/freshqa | Full clone. README and notebooks listed | `7d2d368` (1 May 2026) |
| Director-AI (anulum/director-ai) | **Docs only.** Source file not located | — |
| FreshCtx, FreshContext MCP, StillTrue, VERITY | **README or listing only** | — |
| Tavily API | Docs only. **No live call made: no `TAVILY_API_KEY` in this environment** | — |

Permalink base for Bifrost: `https://github.com/maximhq/bifrost/blob/e869c3f9adc96ea53c38694a21bb04a8e1085487/`. Abbreviated below as `bf:`.

I did not run any third-party code. Cloned repositories were treated as untrusted data.

---

## 1. Competitive audit

### 1.1 Bifrost v2.4.0: verified facts that change our design

| # | Finding | Evidence |
|---|---|---|
| B1 | `PreLLMHook` and `PostLLMHook` run **once per attempt**, including failed fallback attempts. Only `HTTPTransportPreHook`, `PreRequestHook` and `HTTPTransportPostHook` run once per request | `bf:core/schemas/plugin.go` L237–L262 (lifecycle comment) |
| B2 | When a plugin short-circuits in `PreLLMHook`, **only plugins whose `PreLLMHook` already ran get their `PostLLMHook`**. The semantic cache short-circuits on a hit. It is a builtin, order 7, and custom plugins default to `post_builtin`. So **our `PostLLMHook` never sees a cache hit** | `bf:core/schemas/plugin.go` L269–L272. `bf:plugins/semanticcache/main.go` L379 (`PreLLMHook`). `bf:transports/bifrost-http/server/plugins.go` L317–L323 |
| B3 | `HTTPTransportPostHook` runs once per request, after core, and only over HTTP. On large streamed bodies `resp.Body` may be nil | `bf:core/schemas/plugin.go` L344–L359 |
| B4 | `HTTPTransportResponseHeadersHook` runs once at "the last safe point before response headers are committed", for both buffered and streaming responses, in reverse registration order. The metadata is pooled and must not be retained | `bf:core/schemas/plugin.go` L361–L375 |
| B5 | **Plugins cannot register HTTP routes.** Transport hooks are added only to the inference middleware chain. Unknown paths go to the router's NotFound handler. A report endpoint therefore needs a **small in-tree handler**, following the pattern of `handlers/cache.go` (the cache-clear routes) | `bf:transports/bifrost-http/server/server.go` L3737–L3746, L3230. `bf:transports/bifrost-http/handlers/cache.go` L21–L23 |
| B6 | Builtin plugins are compiled in and dispatched by a `switch` in `loadBuiltinPlugin`. Custom `.so` plugins go through `PluginLoader.LoadPlugin`. **Release builds are statically linked** (`-extldflags "-static"`), so a `.so` cannot load into an official binary. In-tree registration means editing `server/plugins.go` (two small blocks) | `bf:transports/bifrost-http/server/plugins.go` L84–L199, L201–L209, L237–L360. `bf:Makefile` L393–L413 |
| B7 | Each plugin is its own Go module (`plugins/semanticcache/go.mod`, `go 1.27.3`). **The local toolchain is go1.25.1.** `GOTOOLCHAIN=auto` should fetch 1.27.3. Untested | `bf:plugins/semanticcache/go.mod` |
| B8 | The semantic cache writes the lookup result, **including the `cache_id` a miss will be written under, to the request context in `PreLLMHook`**. Later hooks can read it with `schemas.CacheLookupFromContext(ctx)` | `bf:plugins/semanticcache/main.go` L491–L507. `bf:core/schemas/cachemetadata.go` L51–L66 |
| B9 | The cache TTL is read **at write time** inside the semantic cache's `PostLLMHook`, from `ctx.Value(semanticcache.CacheTTLKey)`. Post-hooks run in reverse order, so **our `PostLLMHook` runs before the cache's**, and a TTL we set synchronously takes effect. The write itself happens on a background goroutine with its own timeout | `bf:plugins/semanticcache/main.go` L249, L662, L882–L900, L966–L986 |
| B10 | `ClearCacheForCacheID` and `ClearCacheForKey` exist. Over HTTP: `DELETE /api/cache/clear/{cacheId}` behind management auth | `bf:plugins/semanticcache/main.go` L1022, L1059. `handlers/cache.go` L22–L23 |
| B11 | **There is no TTL-extension API.** You can only set a TTL at write time or delete an entry | Same file. No update path found |
| B12 | Identity is on the context: `BifrostContextKeyGovernanceVirtualKeyID/Name`, `...TeamID`, `...CustomerID`, `BifrostContextKeyRequestID`. The raw `x-bf-vk` value is under `BifrostContextKeyVirtualKey` | `bf:core/schemas/bifrost.go` L265–L269, L520–L552 |
| B13 | `ctx.CalculateCost` **must be called synchronously**. Reading the context after the request is cancelled is unsafe. The docs show the pattern: compute in the hook, then close over the value in a goroutine | `bf:core/schemas/context.go` L978–L1000 |
| B14 | **The model catalog has no knowledge-cutoff field.** `GetModelInfo` returns pricing, context and deprecation data, but grep finds no cutoff or training-date field | `bf:core/schemas/context.go` L956–L976. Grep on `models.go`, `modelcatalog.go`, `modelcaps.go` |
| B15 | `ObservabilityPlugin.Inject` is called asynchronously after the response is written, with a per-plugin semaphore (default 10,000) and a 5 s inject timeout. The trace is pooled and must be copied. **I did not verify that traces carry response text**, so we won't depend on this | `bf:core/schemas/plugin.go` L574–L611 |
| B16 | **Relays.** Cost = `units` (read via gjson at `units_path`) × `cost_per_unit` (USD) + `cost_per_request` + any upstream-reported cost. A missing units path means "no units", so only the flat fee is charged. The governance plugin checks budgets in `PreRelayHook` and charges in `PostRelayHook`. Budgets are USD | `bf:core/relay/usage.go` L116–L135, L275–L280. `bf:core/schemas/relay.go` L105–L117. `bf:plugins/governance/relays.go` L23–L99. Bifrost docs `relays/pricing` (per-credit example: `usage.credits`, `cost_per_unit` 0.008) |
| B17 | Streams: `PauseStream`, `TransformPausedStreamBuffer` and `GetAccumulatedResponse` exist, so a future streaming Protect mode is possible. They need a real tracer, which the HTTP server wires | `bf:core/schemas/context.go` L814–L960 |

### 1.2 Related projects

| Project | What it actually implements (from code) | Overlap with Halflife | Visible limitations | Tests or evidence | License · activity | What we take (as ideas, not code) |
|---|---|---|---|---|---|---|
| **dokis** | Deterministic **support** checking for *RAG chunks the caller supplies*. Claimify-inspired regex extractor (`dokis/core/extractor.py`, 1,194 lines). BM25 claim→chunk matching (`matcher.py`). Freshness = **age of the supporting chunk's metadata date** vs `max_source_age_days` (`dokis/core/freshness.py` L43–L67), giving `supported_fresh`, `supported_stale` or `unsupported` | Claim extraction. "Freshness" verdict vocabulary | **No retrieval, no web, no LLM.** "Stale" means *the source is old*, not *the claim changed*. It can't tell you a price is wrong today | 160 test functions. Claimify-selection benchmark on 6,490 rows: regex F1 0.776, claimify-mode F1 0.805 (`benchmarks/results/.../claimify_selection_summary.md`) | MIT · last push Apr 2026 · 36★ | Cheap deterministic pre-filter for non-claims (questions, advice, headers) before any LLM call |
| **fact-checking-agent** | spaCy sentence split plus a conjunction rule. Tavily search with **only `query` and `max_results`** (`src/search.py` L66–L67). NLI cross-encoder stance. Domain-suffix reliability (`src/reliability.py` L16–L28). Reliability-weighted stance vote (`src/agent.py` L43–L57) | **Directly overlaps a naive version of our engine** (claims → Tavily → stance → score) | No time awareness. No dates or freshness parameters. Its own "10 claims, 9/10" gold set uses an *offline* 6-document corpus | 4 test files. RESULTS.md: 10 claims, offline | **No license file (all rights reserved)** · Sep 2026 · 0★ | Nothing reusable legally. Confirms what a "simple Tavily checker" competitor looks like |
| **facticli** | Multi-stage LLM agent (plan, research, review, judge). OpenAI web search or Brave. Deterministic authority tiers (`core/source_quality.py` L443 `classify_source_tier`). Run-level token and retry budgets (`core/usage.py` L37–L57). Error taxonomy (`core/errors.py`). The judge must argue the opposing verdict and caps confidence >0.9 unless two independent primary or reference sources agree (`prompts/judge.md` L20–L34). AVeriTeC evaluation harness | General claim verification, source tiers, budgets, evidence-gap reporting | **Not temporal.** Only a prompt line about "stale sources on time-sensitive claims". Not Tavily. Not a gateway. Per-claim cost is high (multi-stage agent) | Large test suite (≈20 files). AVeriTeC eval scripts. I did not reproduce its scores | **No LICENSE file. `pyproject.toml` says CC-BY-SA-4.0 (share-alike)** · Oct 2026 · 1★ | Ideas: tier labels shown to the judge, counter-argument step, rule-based confidence caps, explicit evidence gaps. **Do not copy code (share-alike)** |
| **RecencyQA** | 4,307 questions (README says 4,031; the file has 4,307). **12 ordinal recency labels** ("An-Hour" to "Never") plus stationarity. Labels are LLM-generated (`Prompts/recency_labeling_prompt.txt`). Human validation reported at 76% (recency) and 78% (stationarity) | Our "how volatile is this fact" estimate | Question-level, not claim-level. Labels are LLM-produced and noisy. Skewed: A-Few-Years 1,318, Never 857, An-Hour 262. The paper link is a placeholder | Dataset only. No eval code beyond prompts | MIT · Oct 2026 | **Use its 12-class scale (collapsed to 5 bands) as our volatility vocabulary, and a held-out slice to evaluate our volatility classifier** |
| **FreshQA** | 600 questions with fast-, slow- and never-changing categories plus false-premise. FreshEval strict and relaxed LLM grading notebooks. Ground truth is maintained manually in Google Sheets | Evaluating time-sensitive answers | **The latest public snapshot is 21 Apr 2026, and the "next update: May 11, 2026" never appeared.** As of today its answers are 6 months stale. That is the problem we're solving, in the benchmark itself | Notebooks, no unit tests | Apache-2.0 code. Dataset terms are in the sheet · last push May 2026 | **Snapshot diffs (Nov 2024 → Apr 2026) are real, dated "answer changed" events.** Mine them as stale-claim candidates. Every label must be re-verified as of our snapshot date |
| **Director-AI temporal refresh** | Per docs: flags temporal claims, queries with the *subject only* ("querying with the value would just return pages echoing it"), lexical `supported`/`drift_suspected` path or NLI `supported`/`contradicted`. DuckDuckGo parser in its benchmark. Offline 10-case result: precision 1.00, recall 0.80 | **Closest algorithmic prior art for T1** | Lexical path misses drift when an old office-holder's name persists. Tiny evaluation. Library, not gateway | Docs claim tests. Source not inspected | GitHub reports Apache-2.0, but the feature page says "LicenseRef-BUSL-1.1… TDM requires permission". **Treat as encumbered** · active | **Subject-only query construction**: a good idea we should independently adopt and credit |
| FreshCtx / FreshContext MCP | FreshCtx: time-of-check vs time-of-use revalidation of an *agent's declared dependencies* (files, DB rows, APIs). FreshContext: decay-weighted ranking of RAG context | Vocabulary (CURRENT, STALE, UNVERIFIABLE) | Different problem: neither verifies world-fact claims in an LLM answer | README only | Apache-2.0 / MIT | None needed |
| Bifrost guardrails (Patronus etc.) | Output guardrails, including "post-delivery monitor" mode. Patronus is the only provider with hallucination detection | Gateway placement of output checks | Docs live under `/enterprise`. Hallucination against *given context*, not live freshness | Docs only | Enterprise (assumed) | Our plugin should look like a guardrail to operators (modes, monitor) without depending on Enterprise |

**No existing issue or PR in maximhq/bifrost** proposes claim freshness verification or freshness-aware cache invalidation (issue search on 31 Oct: "freshness", "fact check", "grounding", "hallucination" and "stale" turned up only provider bugs and guardrail docs).

### 1.3 Feature matrix

| Capability | dokis | fact-checking-agent | facticli | Director-AI refresh | Simple Tavily checker (expected competitor) | **Halflife (planned)** |
|---|---|---|---|---|---|---|
| Claim extraction | ✅ deterministic | ⚠️ sentence-level | ✅ LLM | ✅ | ✅ LLM | ✅ LLM, with deterministic pre-filter |
| Live web retrieval | ❌ | ✅ Tavily (minimal) | ✅ OpenAI/Brave | ✅ DDG | ✅ Tavily | ✅ Tavily, per-class policy |
| Time-aware selection (which claims can go stale) | ❌ | ❌ | ❌ | ⚠️ undocumented scorer | ❌ | ✅ temporal scope + volatility band + age |
| Distinguishes OUTDATED vs never-true vs historical | ❌ | ❌ | ❌ | ⚠️ drift only | ❌ | ✅ (§3) |
| Typed value comparison (version, price, person, date) | ❌ | ❌ | ❌ | ⚠️ lexical | ❌ | ✅ deterministic comparators |
| Spend budget | ❌ (no spend) | ❌ | ✅ token budget | ❌ | ❌ | ✅ **Bifrost budgets on LLM tokens and Tavily credits, per tenant** |
| Runs with zero app changes | ❌ library | ❌ CLI | ❌ CLI | ❌ library | ❌ | ✅ **gateway plugin** |
| Fixes cached stale answers | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ **TTL at write plus invalidation (B8–B10)** |
| Per-tenant attribution and metrics | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Published evaluation | ✅ extraction only | ⚠️ 10 offline claims | ✅ AVeriTeC | ⚠️ 10 cases | — | **planned, held-out** |

---

## 2. Originality verdict

**The verification engine itself is not novel.** Claim extraction, search-based verification, stance judging and source tiers all exist (fact-checking-agent, facticli, Director-AI, DeepMind's SAFE). If Halflife's pitch is "we check claims against Tavily", it is a better-engineered version of something judges will see several times.

**What remains genuinely ours**, and what no audited project provides:

1. **(A) Gateway-native, tenant-attributed auditing with governed spend.**
   - One Bifrost integration covers every app on the gateway.
   - Each report carries the caller's virtual key, team and customer (B12).
   - The verifier's LLM tokens *and* Tavily credits are charged to a Bifrost budget via virtual keys and Relays (B16).
   - Verifier outages are absorbed by Bifrost fallbacks.
   - Only possible inside the gateway.
2. **(C) Temporal cache correctness.**
   - The gateway's cache is the one place where a stale answer gets *multiplied* across users.
   - v2.4.0 exposes exactly the lifecycle needed (B8–B11): the `cache_id` is known on the request context, a per-request TTL can be set before the write, and the entry can be deleted later.
   - Halflife can shorten TTLs for volatile answers at write time and evict entries whose claims are found OUTDATED.
   - I found no implementation of this anywhere.
3. **(B) Adaptive verification budgeting, as the *measured* claim.**
   - Picking claims by temporal scope and volatility should match verify-all's stale recall at lower cost.
   - **This is a hypothesis, not a result.** If the evaluation doesn't support it, we drop the claim and keep A and C.

**Demoted:**
- (D) Evidence-aware verdicts are a *quality bar*, not a differentiator. Everyone claims them.
- (E) Observability is minimal: Prometheus counters and a report list. Dashboards impress nobody.

**Answer to the difficult question** ("why prefer Halflife over a simple Tavily checker?"):

A checker only sees answers someone sends it. It can't:
1. Cover the 12 apps nobody integrated it into.
2. Stop the gateway cache from serving the same outdated answer to the next 1,000 users.
3. Charge its own search and LLM spend to the tenant that caused it, and refuse when that budget is gone.
4. Keep working when its LLM provider fails, without code changes.

Halflife does all four, and we can demonstrate each one live.

On per-claim *accuracy*, we will claim parity or better **only if** the held-out evaluation shows it.

**Improvement over the Phase 1 concept:** make **temporal cache correctness** a headline capability, not an optional extra. It is the honest answer to "async audit doesn't protect the first user": audit catches the first stale answer, and cache eviction protects every user after it.

---

## 3. Algorithm, revised

### 3.1 Critique of the Phase 1 formula `P(stale) = 1 − exp(−Δt/τ)`

1. **The "half-life" label was wrong.** With τ as written, τ is the *mean time to change* of a Poisson process. The half-life is τ·ln 2. The half-life form is `1 − 2^(−Δt/h)`.
2. **The memoryless assumption fails for many claim types.**
   - Prices, releases, terms of office and laws change on schedules (quarterly pricing, annual releases, fixed terms, effective dates).
   - RecencyQA's *non-stationary* class (949 of 4,307) shows the rate itself depends on context (elections, crises).
3. **The model knowledge cutoff is a poor reference date.**
   - Bifrost doesn't expose it (B14).
   - Vendors publish it inconsistently.
   - Effective knowledge often lags the stated cutoff.
   - The answer can come from an app's *retrieved context*, not the model's memory.
4. **Temporal qualifiers change the question.**
   - "As of 2023, X was CEO" is a *historical* claim. It isn't stale even if X has left.
   - "X is CEO" asserts the present.
   - Scope must be extracted before any risk estimate.
5. **Some claims are wrong at generation time.** That's hallucination, not staleness. P(stale) ≠ P(wrong). A claim that was never true must not be reported as "outdated".
6. **Importance matters** (a wrong price or legal requirement versus a wrong founding trivia date), but importance is a policy choice. It belongs in operator config as class weights, not in a learned model.
7. **History can help.** FreshQA snapshot diffs and RecencyQA labels give empirical change-frequency *bands*. With ~240 labelled claims we **cannot** calibrate a probability. Calling the output a probability would be unjustified.

### 3.2 Four distinct outputs, never merged

| Output | Meaning | Form | How it's produced |
|---|---|---|---|
| **Verification priority** | Should we spend money checking this claim? | `HIGH / MEDIUM / LOW / SKIP` plus a reason string | Rules (§3.3) |
| **Verdict** | What the evidence says | `CURRENT · OUTDATED · CONTRADICTED · CONFLICTING · UNVERIFIABLE · NOT_CHECKED` | Retrieval, then value comparison and judge (§3.4) |
| **Evidence strength** | How strong the evidence behind the verdict is | `STRONG / MODERATE / WEAK` plus the rule that fired | Deterministic rules (§3.5) |
| **Freshness score (T1 deliverable)** | A per-claim 0–100 number the statement asks for | **Labelled "heuristic score" in the UI.** Derived from verdict × strength via a fixed table. Never shown as a probability | Table (§3.5). Its monotonicity is checked on held-out data |

**OUTDATED vs CONTRADICTED:**
- *OUTDATED* requires evidence that the claimed value **was** true and has since changed. Examples: a dated source supporting the old value, "replaced", "previously", "as of", a changelog sequence.
- *CONTRADICTED* means current authoritative sources disagree, but there's no evidence the claim was ever true.
- Only OUTDATED counts as "demonstrably outdated" in the UI, metrics and cache eviction.

### 3.3 Selection method (simplest defensible)

**Step 1. Extraction.** One cheap LLM call through Bifrost, after a deterministic pre-filter that drops questions, advice and headers (an idea from dokis, implemented by us). Each atomic claim gets:
- `text`
- `subject` (the thing the claim is about) and `asserted_value`
- `category` ∈ {version, price, leadership/role, law/regulation, statistic, event/date, other}
- `temporal_scope` ∈ {CURRENT, HISTORICAL, TIMELESS, FUTURE, UNCLEAR}
- `as_of` date if stated
- `volatility_band` ∈ {HOURS–DAYS, WEEKS–MONTHS, ~YEAR, YEARS, NEVER}. This collapses RecencyQA's 12 classes; the prompt is our own, inspired by its taxonomy.

Negation and multi-claim sentences are split here, e.g. "X no longer supports Y, and Z costs $5" becomes two claims with negation preserved.

**Step 2. Priority rules** (deterministic, configurable):
- `TIMELESS`, `NEVER` band, or `HISTORICAL` with an explicit `as_of` → **SKIP**. The reason is recorded. Historical claims are out of scope for *freshness*.
- `CURRENT` or `UNCLEAR`:
  - `elapsed = now − reference_date`. The reference is `as_of`, else the model's configured cutoff from our own `model → cutoff` table, else a conservative default of 18 months.
  - **HIGH** if `elapsed ≥ lower bound of the band's change interval`, or the claim says "latest", "current", "now" or similar.
  - **MEDIUM** if within 2× of that bound.
  - **LOW** otherwise.
- Operator class weights (e.g. price, law) can raise one level.

**Step 3. Budgeted selection.** Pick claims in priority order, then by class weight and lowest estimated credits, until the per-request credit cap is reached. Unselected claims are `NOT_CHECKED` with the reason "budget" or "low priority". This is shown, not hidden.

**Alternatives to compare in the evaluation, as ablations rather than features:**
- (a) verify-all
- (b) random-k at equal cost
- (c) LLM-only "is this likely outdated?" ranking
- (d) rules without `elapsed` (scope and band only)

**If (d) does as well as the full rule, ship (d).**

### 3.4 Verification

1. **Query construction: subject-only** for value claims, e.g. "OpenAI GPT-x API price per 1M input tokens", not the asserted value. This was independently reasoned; Director-AI documents the same insight, and we credit it.
2. **Tavily Search policy per category:**

   | Category | Search settings |
   |---|---|
   | version | `exact_match` on the product name, `include_domains` = official docs and release hosts with `include_domains_mode: prefer` |
   | price | vendor domain with `prefer`; `topic: finance` only for securities |
   | leadership | `topic: news`, `time_range: year` |
   | law | government domains with `prefer` |

   All categories use `search_depth: basic`, `max_results: 5`, `chunks_per_source: 3`, `include_published_date: true`, `include_usage: true`.

   `max_age_hours: 0` is used **only for the HOURS–DAYS band**. On non-paying plans it can be refused with 434 "Flex tier capacity exceeded"; on 434 we retry without it.
3. **Primary-source extract (optional, ≤1 per claim):** Tavily Extract with `query` set to the subject, on the top official-domain URL, when Search chunks don't contain the value.
4. **Typed value comparison before any LLM judging.** An LLM reads the current value *from evidence* in structured output. Deterministic comparators then decide equality:
   - semver/version ordering
   - price (amount, currency, unit, per-token basis)
   - person name normalisation
   - dates

   The LLM judge decides only free-text claims and the OUTDATED-vs-CONTRADICTED distinction.
5. **Untrusted evidence handling:**
   - Evidence text goes into a delimited data block.
   - The judge has no tools.
   - Output is schema-validated, with one retry, then `UNVERIFIABLE (malformed)`.
   - Every cited quote must appear verbatim in the fetched text, or the verdict is downgraded to `UNVERIFIABLE`.
   - Instruction-like strings in evidence are flagged in the report.
6. **`published_date` is evidence metadata, not proof.**
   - It's Tavily's estimate (beta).
   - It's used only to (i) prefer the newest *authoritative* statement among conflicting ones and (ii) support OUTDATED (an older dated source showing the old value).
   - A recent date never makes a claim CURRENT on its own.
7. **Failure semantics:**

   | Failure | Result |
   |---|---|
   | Search error or 5xx | Retry once |
   | 429 | Honour `Retry-After` |
   | 432 / 433 (plan or PayGo limit) | Stop the job and mark claims `NOT_CHECKED (provider limit)` |
   | Relay 402/403 (budget or grant) | `NOT_CHECKED (budget)` |
   | No results | `UNVERIFIABLE (no evidence)` |
   | Sources disagree after authority weighting | `CONFLICTING`, with both sides shown |

### 3.5 Evidence strength and the heuristic score

**Evidence strength** (inspired by facticli's confidence caps, but our own rules):

| Strength | Rule |
|---|---|
| **STRONG** | ≥2 independent registrable domains agree, at least one *primary* (official domain for the subject), and the quote is verified verbatim |
| **MODERATE** | One primary source, or ≥2 non-primary sources agreeing |
| **WEAK** | Anything else |

**Freshness score table** (fixed, labelled heuristic):

| Verdict | STRONG | MODERATE | WEAK |
|---|---|---|---|
| CURRENT | 90 | 75 | 60 |
| OUTDATED / CONTRADICTED | 5 | 15 | 30 |

CONFLICTING = 45. UNVERIFIABLE and NOT_CHECKED show "—" with the priority.

**Validation:** on held-out data, report the share of claims actually current within each score bucket. If buckets aren't monotonic, we say so.

---

## 4. Corrected architecture

### 4.1 Integration points (all in the v2.4.0 OSS source)

| Need | Hook / API | Notes |
|---|---|---|
| Report ID | Generated in `HTTPTransportPreHook` (or derived from `BifrostContextKeyRequestID`) and stored on the context | Once per request |
| Recursion guard | `HTTPTransportPreHook`: if `GovernanceVirtualKeyID` ∈ the configured verifier key IDs → mark the context `halflife-skip` | **Matching on the governance-resolved key ID, not a header, can't be spoofed without that key's secret.** A header marker is kept as defence in depth |
| Capture the typed final response | `PostLLMHook`: if `bifrostErr == nil && resp != nil`, stash a copy on the context (last successful attempt wins). Compute `ctx.CalculateCost(resp)` here, synchronously (B13). Never modify `resp` | Failed attempts are ignored by construction (B1) |
| Short TTL for volatile answers | `PostLLMHook`: cheap deterministic volatility scan of the answer (regex for versions, prices, "latest", "CEO", years). If it hits, `ctx.SetValue(semanticcache.CacheTTLKey, shortTTL)` | Works because our post-hook runs before the cache's (B9). Must stay a fast rule, no LLM call |
| Cache hits | `HTTPTransportPostHook`: `schemas.CacheLookupFromContext(ctx)`. On a hit, link to the existing report for that `cache_id` instead of re-verifying (B2, B8) | Our `PostLLMHook` doesn't run on hits |
| Schedule the job | `HTTPTransportPostHook` (once, final): if status is 2xx and not skipped, copy *all* needed data (answer text, model, provider, identity fields, cost, cache_id) into a job struct and **non-blocking send** to a bounded queue | If the queue is full: drop and increment `halflife_jobs_dropped_total` |
| Report header | `HTTPTransportResponseHeadersHook`: set `x-halflife-report: <id>`, or `x-halflife-status: skipped|dropped` | Before commit, buffered and streaming (B4) |
| Workers | Fixed pool (default 4). Each job uses `context.WithTimeout(context.Background(), 90s)`. Panic recovery. `Cleanup()` drains with a deadline | The same pattern the semantic cache's `cacheWriter` uses (B9) |
| Verifier LLM calls | Loopback HTTP to `/v1/chat/completions` with `x-bf-vk: <verifier key>` | Gets fallbacks, logs, cost and budget |
| Tavily calls | Loopback HTTP to `/relay/tavily/search` and `/relay/tavily/extract` with the verifier key | Relay pricing: `units_path: usage.credits`, `cost_per_unit` = shadow USD price |
| Eviction | On an OUTDATED verdict for an answer with a `cache_id`, call `ClearCacheForCacheID`. In-process if the handler pattern lets us resolve the plugin, otherwise `DELETE /api/cache/clear/{id}` with an admin credential. Retry after the cache-write timeout if the entry isn't there yet | The async write can race with the job (B9) |
| Report API | **New in-tree handler** (`handlers/halflife.go`): `GET /api/halflife/reports/{id}`, `GET /api/halflife/reports?vk=…`, `POST /api/halflife/verify`. Registered with management or auth middleware | Plugins can't add routes (B5). This is a disclosed server modification in our fork |
| Metrics | Prometheus counters and histograms registered through the telemetry plugin's registry (to verify), else our own `/metrics` subtree on the handler | Kept minimal |
| Storage | SQLite file (reports, claims, evidence). Retention TTL (default 7 days) | Content-logging toggle (§4.3) |

### 4.2 Assumptions removed or downgraded since Phase 1

| Phase 1 assumption | Status |
|---|---|
| "Ship as a `.so`" | Official binaries are static. We use **in-tree compilation** in a fork. `.so` is dropped |
| "Plugin serves `/halflife/report/{id}` via a pre-hook short-circuit" | **False.** Needs an in-tree handler (B5) |
| "Read the knowledge cutoff from the model catalog" | **False.** We keep our own config table (B14) |
| "Audit in `PostLLMHook`" | Partly wrong. Per-attempt semantics and missed cache hits. Now we capture in `PostLLMHook` and finalise in `HTTPTransportPostHook` |
| "Extend TTL when verified CURRENT" | **No API.** Only set at write time or evict (B11) |
| "Closed-loop routing via injected `web_search`" | Dropped from scope |
| "Score = probability the claim is true" | **Withdrawn.** Now a heuristic score, labelled as such (§3.5) |
| "Use `max_age_hours: 0` for all volatile claims" | Limited to the HOURS–DAYS band, with a 434 fallback |

### 4.3 Security design (built in from M3, not deferred)

| Threat | Control |
|---|---|
| Prompt injection via retrieved pages | Data delimiting, no tools for the judge, schema validation, verbatim-quote check, flag instruction-like spans, never execute evidence content. Tested with recorded-fixture injection cases |
| Unauthorised report access | Report routes behind Bifrost management auth. Non-admin reads are filtered by the caller's resolved virtual key ID. Report IDs are random 128-bit values, not sequential |
| Cross-tenant leakage | Reports stored with key, team and customer IDs. Every list or get filters by the caller's identity. **Evidence and results are never shared across tenants** (no cross-tenant memoisation in the MVP) |
| Unbounded background work | Bounded queue, fixed workers, per-job deadline, per-request claim cap (default 8), per-request credit cap, drop counter |
| Recursive requests | Verifier-key-ID guard plus a header marker. Verifier keys have **no** Halflife audit. Tested in M1 |
| Secret exposure | Tavily key only as a Relay credential (`env.` reference). Verifier key from env. Nothing secret logged. Report JSON redacts headers |
| Sensitive content logging | `store_answer_text` defaults to **claims only, not the full answer**. Per-key opt-out. Retention TTL. Request bodies never stored |

---

## 5. Revised product specification

### 5.1 MVP: user-visible

1. **Submit or generate**
   - "Generate" sends a prompt through Bifrost.
   - "Paste" posts any answer to `/api/halflife/verify` with model and date hints.
2. **Claims list**
   - Each claim with temporal scope, category, volatility band and **priority with its reason**.
   - Which claims were selected, and which were skipped (and why: low priority, timeless, budget).
3. **Evidence per checked claim**
   - URL, domain tier, `published_date` (shown as "estimated"), verbatim quote, Tavily `request_id`.
4. **Verdict and strength**
   - Verdict, evidence strength, heuristic score, plus a correction (the current value with source) where OUTDATED or CONTRADICTED.
5. **Cost of this audit**
   - Tavily credits (native, from `usage.credits`)
   - USD charged via the Relay
   - Verifier LLM tokens and USD (from Bifrost logs or cost)
6. **Gateway context**
   - Which app (virtual key) produced the answer, which model or provider served it, cache hit or miss, and whether the cache entry was evicted.

### 5.2 Modes

| Mode | Status | Honest description |
|---|---|---|
| **Audit** (async) | **Essential** | Adds no verification latency to the response. **Does not stop the first user seeing a stale answer.** Feeds cache eviction and monitoring |
| **Monitor** | **Essential (minimal)** | Report list filtered by key, team or model. Counters: claims checked, OUTDATED by category or model, credits and USD spent, jobs dropped |
| **Protect** (sync) | **Stretch** (non-streaming only) | Opt-in per request via header. Verification runs before the response, with a hard deadline (default 8 s). On timeout or error, the original response is returned with `x-halflife-status: timeout` (fail-open). Optional annotation, never silent rewriting |

**Cache correctness is essential if M1-C passes (§7).** Otherwise it becomes a stretch goal.

### 5.3 Explicitly out of scope

Streaming verification · `.so` packaging · routing changes · Tavily Research API · multi-language · user accounts · an upstream PR before submission (optional after).

---

## 6. Evaluation plan (designed before building)

### 6.1 Datasets

**HL-Claims v1** (ours), about 240 claims.

| Stratum | Target count | Source |
|---|---|---|
| Recently changed (truly OUTDATED as of snapshot date) | 60 | FreshQA snapshot diffs, re-verified today. Curated version, price, leadership and law changes from Jan–Oct 2026 |
| Stable / timeless | 40 | General knowledge, constants |
| Historical, correctly scoped ("In 2023, …") | 30 | Derived from changed facts |
| Incorrect but never true | 30 | Perturbed values |
| Conflicting sources | 20 | Curated (e.g. disputed figures) |
| Ambiguous | 30 | Underspecified subject or time |
| Unverifiable | 30 | Private or nonexistent entities |

- **Labelling:** two teammates who did **not** write the prompts label each claim independently, with source URL and snapshot date. Cohen's κ is reported. Disagreements go to a third teammate.
- **Split:** stratified **dev 40% / held-out test 60%**. All prompts, rules and thresholds are frozen and committed before the single test run.
- **HL-Answers:** ~50 realistic prompts × 3 models via Bifrost, with claims annotated. Used for extraction recall and the end-to-end demo.
- **RecencyQA** (MIT): a held-out random 400-question sample, used *only* to evaluate the volatility band classifier (5-band accuracy and adjacent-band accuracy). Reported with the caveat that its labels are LLM-generated, with 76% human agreement.
- **Injection set:** 10 recorded evidence fixtures with embedded instructions (replay only).

### 6.2 Systems compared

| ID | System |
|---|---|
| S0 | No verification |
| S1 | **Simple Tavily checker**: extract claims → one `basic` search with the claim text → LLM true/false |
| S2 | **Verify-all**: Halflife retrieval and judging on *every* claim (isolates the effect of selection) |
| S3 | **Halflife adaptive** |
| S4 (optional) | facticli run as an external tool, without copying its code, if its licensing for use is clear |

Ablations of S3: no temporal scope · no `elapsed` term · no typed comparators · no Extract · no quote check · random-k at equal credits.

### 6.3 Metrics

- Extraction recall (HL-Answers)
- Stale (OUTDATED) precision, recall, F1, false-positive rate
- CONTRADICTED-vs-OUTDATED confusion
- Corrected-value accuracy
- Unsupported-verdict rate (verdicts whose quote check failed)
- Coverage (% of claims checked)
- Tavily credits, LLM tokens and USD per answer
- p50/p95 job latency, plus user-path latency added in Audit mode (expected ≈0, **measured**)
- Failure recovery (§6.5)
- Score-bucket monotonicity

**Statistics:** bootstrap 95% CIs over claims for F1 and recall differences.

### 6.4 Pre-registered claims (we may say these only if the data supports them)

| Claim | Condition required on the held-out test |
|---|---|
| "Matches verify-all at lower cost" | S3 stale recall ≥ S2 − 5 pp **and** S3 credits ≤ 60% of S2 |
| "Better detection than a simple checker" | S3 − S1 F1 difference, with 95% CI excluding 0 |
| "Distinguishes outdated from wrong" | OUTDATED precision on the never-true stratum (false-OUTDATED rate) reported. Claimed only if ≤ 10% |

If any condition fails, **we publish the result anyway and drop the claim from the pitch.**

### 6.5 Bifrost operational experiments

1. **Fallback:** revoke the verifier's primary provider key mid-run. Measure the % of jobs completing and the fallback chain in the logs.
2. **Budget:** set the verifier key's budget below one run's cost. Expect refused relay calls, `NOT_CHECKED (budget)`, user requests unaffected (HTTP 200).
3. **Attribution:** three apps on three virtual keys. Per-key report counts and spend must match ground truth.
4. **Cache:** 100 repeated queries over 20 volatile questions with semantic cache on. Count stale answers served with Halflife off vs on (eviction plus short TTL).
5. **Recursion:** the count of audits triggered by verifier traffic must be 0.

### 6.6 Reproducibility

- A record/replay layer stores every Tavily and LLM response keyed by request.
- `make eval` re-runs from recordings deterministically. `make eval-live` re-queries.
- Results are committed with the snapshot date, git SHA, model IDs and Tavily parameters.
- **No metric goes into the README or deck unless it was produced by these scripts.**

### 6.7 Tavily development configuration

| Setting | Choice | Why |
|---|---|---|
| Plan | Free (1,000 credits/month) | Development key limited to 100 RPM |
| Search | `search_depth: basic` (1 credit), `max_results: 5`, `include_raw_content: false`, **`auto_parameters` off** | `auto_parameters` can silently switch to advanced, costing 2 credits |
| Extract | `basic`, batch URLs where possible | Extract `usage.credits` may read 0 until 5 successful extractions; verify on Day 1 |
| `max_age_hours` | Only for the HOURS–DAYS band | 434 risk on free plans |
| Eval runs | Replay | A full live run of 240 claims × (S1+S2+S3) ≈ 1,000–1,500 credits (estimate), which exceeds the free tier. **Budget for the $30 Project plan (4,000 credits) or confirm hackathon credits** |
| Relay pricing | Shadow price `cost_per_unit: 0.008` | Report shows native credits and Bifrost USD **separately**. USD is a shadow price for budgeting, not an invoice |

**Things not verified (no API key):**
- that `usage.credits` is present for Search and Extract with `include_usage`
- how Extract reports fractional credits
- whether `max_age_hours: 0` returns 434 on the free plan
- the exact relay accounting

These are **M1 test items**.

---

## 7. Build roadmap

| Order | Milestone | Depends on | Exit criterion (actual output, logged) | Fallback |
|---|---|---|---|---|
| **M1-A** (Nov 1–2) | Bifrost fork at the v2.4.0 tag builds with Go 1.27.3. Hello-world plugin **registered in-tree** and loaded | Go 1.27.3, Docker | `go build` output plus startup log listing the plugin | Build failing on Nov 2 → assess the `.so` route on a self-built dynamic binary; else pivot (below) |
| **M1-B** | Plugin receives the final successful response. Report ID header present. Async job runs after the response with no added latency | M1-A, one LLM key | curl shows `x-halflife-report`. Timing log shows the job finishing after the response. **A fallback test proves failed attempts aren't audited** | — |
| **M1-C** | Cache lifecycle: `CacheLookupFromContext` gives the `cache_id` on a miss. Our TTL override takes effect. Evicting by ID works | M1-B, Redis | Logs plus a Redis key TTL check | Cache moves to stretch. Differentiation rests on A + B |
| **M1-D** | Tavily via Relay: `/relay/tavily/search` with a granted key. **`usage.credits` present, Bifrost charge = credits × rate**, ungranted key → 403, exhausted budget → refusal | Tavily key | Response bodies plus Bifrost log and budget readings | If the credit field is missing: per-route flat fee and a documented limitation |
| **M1-E** | Recursion guard: verifier-key traffic is never audited | M1-B | Counter = 0 across 20 internal calls | — |
| M2 (Nov 3–4) | Extraction, priority and verification on dev claims (40% split) | M1 | Dev-set metrics logged | Narrow to 4 categories |
| M3 (Nov 5–7) | Full Audit pipeline, report store, in-tree report handler, security controls | M2 | Acceptance tests pass | Sidecar report API |
| M4 (Nov 8–9) | Cache correctness (if M1-C passed). Typed comparators. Monitor counters | M3 | Cache experiment script runs | — |
| M5 (Nov 10–11) | Held-out evaluation, ablations, operational experiments | M4 | `make eval` results committed | Report whatever the data shows |
| M6 (Nov 12–13) | Console: report view, monitor, compare view. Deployment | M5 | Public URL | Local demo plus video |
| M7 (Nov 14) | Demo video, README with AI disclosure and upstream-diff note. **Submit** | M6 | Submission confirmation | Nov 15 buffer |

**Pivot rule:**

- If M1-A or M1-B fails by the end of Nov 2, we do **not** quietly switch to a standalone wrapper while still claiming Bifrost #04.
- Options, re-evaluated against both statements:
  - (i) the `.so` plugin on a self-built dynamic binary, still a genuine plugin (B #04 ✅)
  - (ii) **StaleBench** (Bifrost #02 + Tavily #01), reusing the verification engine
- Choose by whichever still satisfies both statements with the strongest Bifrost depth.

---

## 8. Final decision: **CONDITIONAL GO**

Halflife stays the strongest direction, under specific conditions.

**Why not plain GO:**
- The verification engine is not novel (§2).
- Our edge rests on gateway-specific capabilities that are proven only by reading source, **not by running it**.

**Why not PIVOT:**
- The v2.4.0 source supports every integration point we need (B1–B16). The only server change is the report handler.
- The cache lifecycle we need is already exposed (B8–B11).
- No audited project occupies this position.

**Conditions:**
1. **M1-A, M1-B, M1-D and M1-E pass by the end of Nov 2.** Otherwise apply the pivot rule.
2. **M1-C passes by Nov 3.** Otherwise demote cache correctness and pitch A + B.
3. **Pre-registered claims (§6.4) are only made if the held-out data supports them.**

**Pitch, without marketing:** "A Bifrost plugin that audits every LLM answer on the gateway for claims that have probably changed, verifies them through a governed Tavily relay, attributes and caps the spend per tenant, and stops the gateway's cache from re-serving answers it has proven outdated."

---

## 9. First build milestone: not started

- **Window timing.** The window start isn't confirmed.
  - The organizers never stated a timezone.
  - This machine's clock read **Sun 1 Nov 00:00 IST (31 Oct 18:30 UTC)** when the audit finished. So the window opened only if the organizers use IST.
  - Your instruction was to stop if the start is unclear.
- **Missing prerequisites** for M1 even once timing is confirmed:
  - `TAVILY_API_KEY` (free key)
  - At least two LLM provider API keys, for fallback tests
  - **Go 1.27.3** (installed: go1.25.1)
  - Docker and Redis, for M1-C
- Once you confirm the window is open and provide the keys (as environment variables, never pasted in chat), M1-A to M1-E can run with logged command output, in that order.
