# Evaluation

**Read this first.** No accuracy result for Halflife exists yet. What is here is a small pilot on free models, scored against draft labels that no person has reviewed. It shows the harness works and exposes real weaknesses. It does not show that Halflife catches stale facts on live models. Halflife scored worse than the simple baseline in this pilot. The operational results further down are measured, but mostly against mocks.

## Accuracy pilot

**Data.** 14 claims from the dev split of HL-Claims v1 (2 per stratum). The test split has not been run; the protocol allows it one run, after labels are reviewed. Labels are drafts set by rule (`label_status: draft_pending_review`). There is no inter-rater agreement figure, because no second labeller has labelled anything.

**Systems.**

| System | What it is |
| --- | --- |
| S0 | No verification: every claim stands |
| S1 | Simple checker: one basic search on the claim text, then an LLM true/false |
| S2 | Halflife with priority skipping off (`verify_all`) |
| S3 | Halflife as shipped |

**Run.** Live on 2026-11-04: real Tavily, free OpenRouter models, capped at 60 LLM and 30 Tavily calls by the recording proxy. Each claim is sent through the gateway as a mock model's answer. Responses are in `eval/recordings`; `REC=eval/recordings RUNS=/tmp/pilot VERIFIER_EFFORT=low make eval` replays them with no key or network, and the replay gave the same verdict for every claim in every system. "Stale" means a draft label of OUTDATED, so **only 2 of the 14 claims are positives**.

| System | Exact verdict | Stale precision | Stale recall | Stale F1 (95% CI) | Coverage | Tavily credits | LLM calls |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S0 | 4/14 | n/a | 0.00 | 0.00 (0.00–0.00) | 14/14 | 0 | 0 |
| S1 | 6/14 | 0.25 | 1.00 | 0.40 (0.00–0.73) | 14/14 | 14 | 16 |
| S2 | 5/14 | n/a | 0.00 | 0.00 (0.00–0.00) | 14/14 | 8 | 22 |
| S3 | 2/14 | n/a | 0.00 | 0.00 (0.00–0.00) | 9/14 | 3 | 17 |

Numbers are in `eval/runs/results.json`. With two positives the intervals say little, and no comparison between systems here is meaningful. Latency is not reported as a finding: the figures in the file are dominated by free-tier queues.

S1 did not earn its recall. It called 8 of 14 claims stale, 6 of them wrongly, and returned CONTRADICTED on claims whose draft label is UNVERIFIABLE or CONFLICTING.

### Why Halflife scored as it did

| Finding | Evidence | Status |
| --- | --- | --- |
| Extraction failed on 6 of 14 answers, including both recently changed facts | The free reasoning model spent its 4,096 token limit and returned empty content (`finish_reason: length`); the report says `extraction_failed` instead of guessing | Open: needs a different model |
| The judge returned "the evidence does not say" on most claims that were extracted | S2: 6 UNVERIFIABLE of 8 audited | Open: not yet separated from weak retrieval |
| Priority skipping cost 2 correct verdicts | S2 got one CONFLICTING and one CONTRADICTED right on claims S3 skipped, because extraction tagged them HISTORICAL | Open: a design weakness, not a model limit |
| The strict span check rejected a real stale claim | Retry below: "asserted value is not in the span" | Open: precision is being paid for in recall |

### Capped retry

The two recently changed claims were rerun on S3 at 8,192 tokens, 4 calls in all (`eval/runs-focused`). One claim was rejected at the span check and the other got evidence, but the judge's reply was cut off at the token limit. Neither reached OUTDATED. Live runs stopped there because the free tier allows 50 requests a day.

**So no live run has yet produced an OUTDATED verdict on a recently changed fact in this evaluation.** The OUTDATED path is proven only with scripted model replies (`make claims`, `make experiments`).

### The cause, found after the pilot

The pilot sent `reasoning.effort: low`. One probe each with `none`, on a two-claim extraction with a strict schema: Nemotron 3.5 Super, Xing 4.0 and Dots 3 Note each returned valid JSON with both claims in about 2 seconds, using 67–88 tokens and no reasoning tokens. LFM 2.5 refuses to turn reasoning off. That is 3 small probes, not an evaluation: whether judging holds up without reasoning is untested.

### Next run, free models only

`none` is now the default, in a new recording set (`eval/recordings-v2`, seeded with the pilot's replies so nothing is paid for twice). The free tier allows 50 requests a day and recording resumes, so this runs once a day until the proxy reports no misses:

```bash
LIVE=1 PER_STRATUM=6 MAX_LLM=45 MAX_TAVILY=60 make eval
```

Results land in `eval/runs-v2`. The estimate is about 130 LLM calls for 42 claims, so about 3 days.

### What a real result needs

1. Two people label `eval/hl-claims/review-sheet.csv` independently; compute Cohen's kappa with `eval/hl-claims/review.py`.
2. The run above, then the one test run, which will have to be a sample that fits the daily cap.

## Operational results

These come from the real gateway with mock providers unless stated, and are recorded with commands in [VALIDATION.md](VALIDATION.md).

| Measure | Result |
| --- | --- |
| Request-path latency, paired median | +66.5 µs at concurrency 1, +215.6 µs at concurrency 16 |
| Outdated answers served from the cache, monitor mode | 40 of 40 requested |
| Outdated answers served from the cache, audit mode | 0 of 40 requested, all 40 flagged `known-outdated`, no new audit; current answers kept all 40 hits |
| Tenant isolation | One tenant's exhausted verifier budget pauses only its own audits |
| Failure handling | Rate limits, exhausted credits, server errors and timeouts each handled and reported; answers are never held back |
| Plugin test coverage | 96.1% |

The cache figures depend on scripted verdicts, so they show what the cache does once a verdict exists, not how often a verdict would be right.

## What must not be claimed

- Any precision, recall or F1 for Halflife as a finding.
- That Halflife beats a simple checker. In this pilot it did not.
- Any figure as measured on reviewed labels or on the test split.
