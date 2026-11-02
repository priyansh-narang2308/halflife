# Tavily API: Notes for Halflife

Our own summary of the parts of Tavily that Halflife depends on, read from the full docs on 2 Nov 2026.

**Sources:**
- `https://docs.tavily.com/llms-full.txt` (760 KB, all pages; SHA-256 `ccb133e7…d01`)
- `https://docs.tavily.com/documentation/api-reference/openapi.json` (OpenAPI 3.0.3; SHA-256 `c97103b0…97b`)
- the 10 endpoint pages, the rate-limits page, and the Claude integration page

A local copy is in `research/vendor/tavily-docs/` (gitignored). Facts marked **[docs]** come from Tavily's documentation; **[ours]** marks Halflife design choices; **[unverified]** must be confirmed live (Task 21).

## Our budget

- **[ours]** Account shows 0 / 9,000 credits: the Researcher plan's 1,000/month plus add-on credits. Pay-as-you-go is **off**, so spending stops at the cap with `432` instead of billing.
- **[docs]** Researcher is a non-paying plan. That means a development key at 100 RPM (production keys need a paid plan or PAYGO), and `max_age_hours` requests may get `434` under load.
- **[ours]** Planned spend: about 50 credits for live validation (Tasks 21–23), up to about 6,000 for the evaluation (Task 45), and the remainder held for the demo and judging. Every call sends `include_usage: true` so we can account for it.

## Endpoints we use

| Endpoint | Use in Halflife | Cost **[docs]** |
|---|---|---|
| `POST /search` | Main evidence retrieval for each claim | basic / fast / ultra-fast: 1 credit; advanced: 2 |
| `POST /extract` | Read a page when search snippets are too thin to decide | 1 credit per 5 successful URLs (advanced: 2); failed URLs are free |
| `GET /usage` | Reconcile Bifrost's relay charges against Tavily's own count | free; **10 requests per 10 minutes** |
| `POST /research` | Not in the per-claim loop (4–250 credits per task). Possibly a one-off "deep check" in the demo | — |
| `POST /feedback` | Optional: report bad results (beta) | — |

Base URL `https://api.tavily.com`, auth `Authorization: Bearer tvly-…` **[docs]**.

## Search parameters that matter for stale-claim checks

| Parameter | What it does **[docs]** | Halflife use **[ours]** |
|---|---|---|
| `max_age_hours` | Max age of Tavily's **cached copy** of each page: `1`–`720`; `0` = always fetch live; `-1` = never fetch live. Same credit cost; live fetching adds latency. Pages that are too old and can't be refetched are dropped. **New in October 2026.** | The core freshness lever. Set from the claim's volatility (prices/status → `0`–`6`; versions/leadership → `24`–`168`; slow-moving facts → unset). Fall back to unset on `434`. |
| `time_range` / `start_date` / `end_date` | Filter by page **publish/update date** | Prefer evidence published after the answering model's knowledge cutoff |
| `include_published_date` (beta) | `published_date` per result; `null` if unknown; may be later than the original publish date | Needed to argue "changed after cutoff". Always on |
| `filter_by_published_date` | Drop results outside the window **and** results with no date | Off by default (too lossy); on only for strict re-checks |
| `topic` | `general` / `news` / `finance`; `news` enables published dates | `news` for leadership/events, `finance` for prices/markets |
| `include_domains` + `include_domains_mode: prefer` | `prefer` boosts listed domains without excluding the rest; `prefer` without `include_domains` → 400 | Prefer authoritative domains (vendor pricing page, official releases) without risking empty results |
| `exact_match` | Only results containing the quoted phrase | Entity-pinned queries (`"Acme SDK" latest version`) |
| `search_depth` | `ultra-fast` returns 1 summary per URL; others return reranked chunks (`chunks_per_source` 1–3) | `basic` by default; `advanced` (2 credits) only for HIGH-priority claims where `basic` was inconclusive |
| `auto_parameters` | May silently switch to `advanced` (2 credits) | **Never use**: it breaks budget predictability |
| `max_results` | 0–20. Default is **10 in the OpenAPI spec but 5 on the best-practices page** | Always send explicitly (5) |
| `include_usage` | Adds `usage.credits` | Always `true`; it's what Bifrost's relay `units_path` meters |

Query length must stay under 1,500 characters; one focused query per claim **[docs]**.

## Response fields **[docs]**

- **Search:** `query`, `answer`, `images`, `results[]` (`title`, `url`, `content`, `score`, `raw_content?`, `published_date?`, `favicon?`, `images?`, `id`), `auto_parameters?`, `response_time` (float seconds), `usage{credits}`, `request_id`.
- **Extract:** `results[]` (`url`, `raw_content`, `images?`, `favicon?`), `failed_results[]` (`url`, `error`), `response_time`, `usage{credits}`, `request_id`.
- **Extract with `query`:** reranks chunks; `chunks_per_source` 1–5 (only with `query`); `raw_content` becomes the top chunks joined by `[...]`.
- **Usage:** `/usage` returns `key{usage, limit, search_usage, extract_usage, crawl_usage, map_usage, research_usage}` and `account{current_plan, plan_usage, plan_limit, paygo_usage, paygo_limit, …}`.

## Credit accounting subtlety

**[docs]** "Every 5 successful URL extractions cost 1 API credit," and `include_usage` "may be 0 if the total successful URL extractions has not yet reached 5." Extract credits therefore accrue across calls; they are not rounded up per request.

**Consequence:** Bifrost's relay can only charge what each response's `usage.credits` reports. For Extract, a single request can legitimately show 0 credits. Per-request attribution of Extract cost is approximate; `/usage` is the source of truth for totals. **[unverified]** whether this accrual is per key or per account.

## Errors **[docs]**

All errors use `{"detail": {"error": "…"}}`, except 422, which uses `{"detail": [{type, loc, msg, input}]}` (validation).

| Status | Meaning | Halflife handling **[ours]** |
|---|---|---|
| 400 | Invalid parameters | Bug on our side: log it, mark claim `UNVERIFIABLE` (reason `retrieval_error`) |
| 401 | Missing/invalid key | Fail closed, alert the operator |
| 422 | Field validation failed | Same as 400 |
| 429 | Rate limited; honour `Retry-After` (message text varies, so don't match on it) | Back off per `Retry-After`; bounded retries |
| 432 | Plan or key credit limit reached | Stop all verification (budget exhausted), surface in the report |
| 433 | Pay-as-you-go limit reached | Same as 432 (PAYGO is off for us) |
| 434 | Flex-tier capacity: refused live fetch (`max_age_hours`) on non-paying plans under load | Retry once **without** `max_age_hours`, and record that the evidence came from cache |
| 500 | Server error | Bounded retry, then `UNVERIFIABLE` |

## Rate limits **[docs]**

- Development key: 100 RPM (Search/Extract/Map). Production key: 1,000 RPM (needs a paid plan or PAYGO).
- Crawl: 100 RPM. Research: 20 RPM. `/usage`: 10 per 10 minutes.
- Concurrency rule of thumb from the docs: `≈ (RPM / 60) × avg_latency_s`, so about 5 in flight at 100 RPM and 3 s latency. **[ours]** Halflife's worker pool caps in-flight Tavily calls at 4.

## Attribution headers (strong fit for Halflife) **[docs]**

- `X-Project-ID`: attributes requests to a project in Tavily's usage dashboard and `/logs`; one key can serve many projects.
- `X-Session-Id`: groups related requests; `X-Human-Id`: opaque, hashed end-user ID.

**[ours]** Halflife sends:
- `X-Project-ID` = the requesting app's Bifrost virtual-key ID (or a stable hash of it), so tenant attribution is visible **inside Tavily too**, independent of Bifrost's budgets.
- `X-Session-Id` = the Halflife report ID, so all evidence calls for one audited answer are grouped.

**[unverified]** Whether Bifrost relays forward these request headers upstream (Task 20). `/logs` is listed for paid plans, so we may not be able to read it back on Researcher.

## Claude integration page

`documentation/integrations/claude` covers adding Tavily to Claude Code (official plugin `tavily@tavily-plugins`, or the hosted MCP server `https://mcp.tavily.com/mcp/`) and to claude.ai/Desktop as a connector. That's for using Tavily inside a coding assistant, not for Halflife's runtime path, which calls the REST API through a Bifrost relay so that spend is governed and attributed.

There's also a docs MCP server (`https://docs.tavily.com/mcp`). Neither is installed: installing would change your Claude Code config, and the plugin would spend your credits.

## Mock corrections (applied to `testenv/mocktavily`)

- Search default `max_results` 5 → **10** (OpenAPI value).
- 434 message → the documented live-fetch text.
- Extract credits → accrue per 5 successful URLs **across requests** (per key), so a request can report 0.
- `include_domains_mode` without `include_domains` → 400; 422 shape for type errors.
