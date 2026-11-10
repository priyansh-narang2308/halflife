# Evaluation

**Read this first.** These are early results from free models, scored against draft labels that no person has reviewed yet. In the 42-claim dev run below, Halflife as shipped (S3) had the best stale-answer F1 of the four systems: 0.77, against 0.53 for the simple baseline. It also used fewer Tavily credits than verifying every claim. But the set has only 6 stale claims, the confidence interval runs from 0.43 to 1.0, and the scoring rule changed after the first day (details below). Read it as a promising signal, not a finding. The smaller pilot that came first, where Halflife lost to the baseline, is kept below with its cause and fix. The operational results further down are measured, but mostly against mocks.

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
| Extraction failed on 6 of 14 answers, including both recently changed facts | The free reasoning model spent its 4,096 token limit and returned empty content (`finish_reason: length`); the report says `extraction_failed` instead of guessing | Cause found, see below; re-measure in the next run |
| The judge returned "the evidence does not say" on most claims that were extracted | S2: 6 UNVERIFIABLE of 8 audited | Open: not yet separated from weak retrieval |
| Priority skipping cost 2 correct verdicts | S2 got one CONFLICTING and one CONTRADICTED right on claims S3 skipped, because extraction tagged them HISTORICAL | Open: a design weakness, not a model limit |
| The strict span check rejected a real stale claim | Retry below: "asserted value is not in the span" | Fixed, re-measure in the next run |

### Capped retry

The two recently changed claims were rerun on S3 at 8,192 tokens, 4 calls in all (`eval/runs-focused`). One claim was rejected at the span check and the other got evidence, but the judge's reply was cut off at the token limit. Neither reached OUTDATED. Live runs stopped there because the free tier allows 50 requests a day.

**So no live run has yet produced an OUTDATED verdict on a recently changed fact in this evaluation.** The OUTDATED path is proven only with scripted model replies (`make claims`, `make experiments`).

### The cause, found after the pilot

The pilot sent `reasoning.effort: low`. One probe each with `none`, on a two-claim extraction with a strict schema: Nemotron 3.5 Super, Xing 4.0 and Dots 3 Note each returned valid JSON with both claims in about 2 seconds, using 67–88 tokens and no reasoning tokens. LFM 2.5 refuses to turn reasoning off. That is 3 small probes, not an evaluation.

One judge probe followed, a direct call with the real prompt and schema on the Berber year claim, using the real Tavily evidence from the retry. In 3.7 seconds and 110 tokens Nemotron answered CONTRADICTS with a current value of 2976 and quoted Wikipedia's calendar table, and also found a history quote. It did not go through the gateway, so the quote check and comparators did not run on it. It is the first stale fact caught on a live model, and it is one example.

The span rejection is fixed: a span that stops short of its value now grows to the sentence holding both, and a value in another sentence stays rejected (`TestSpanGrowsToTheSentenceHoldingTheValue`).

## Dev-split run, free models

**Data.** 42 claims from the dev split (6 per stratum), with draft labels. 6 of them are labelled OUTDATED. The test split has not been run.

**Setup.** The models were free OpenRouter models with reasoning set to `none`, plus real Tavily (basic depth). The run was recorded over two days by the replay proxy (`eval/recordings-v2`), so `make eval` replays it offline with no keys. Results are in `eval/runs-v2/results.json`.

| System | Stale F1 (95% CI) | Precision | Recall | Coverage | LLM calls | Tavily credits |
| --- | --- | --- | --- | --- | --- | --- |
| S0 always current | 0.00 | n/a | 0.00 | 1.00 | 0 | 0 |
| S1 simple checker | 0.53 (0.20 to 0.77) | 0.38 | 0.83 | 0.48 | 88 | 42 |
| S2 Halflife, verify all | 0.71 (0.36 to 0.93) | 0.62 | 0.83 | 0.90 | 89 | 38 |
| **S3 Halflife as shipped** | **0.77 (0.43 to 1.00)** | **0.71** | 0.83 | 0.43 | 60 | 18 |

**What it shows.** S3 caught 5 of the 6 stale claims and raised 2 false alarms, for 60 LLM calls and 18 Tavily credits. That is fewer than half the credits S2 used for verifying everything. Coverage is lower because S3 chooses not to check claims it scores as low risk. Halflife is designed to spend that way.

**Caveats.**

- The labels are drafts. With 6 positives, one verdict moves F1 by about 0.1.
- The scoring rule was changed after the first day's results. Originally only an OUTDATED verdict counted as a flag for Halflife. Now every system is flagged for OUTDATED or CONTRADICTED. S1 could only ever say CONTRADICTED, so the old rule was unfair to Halflife. Strict recall (OUTDATED only) is reported separately, and it is 0 for every system. No live claim reached OUTDATED, because that needs a verified quote showing the old value was once true.
- In the same change, cache eviction began to cover CONTRADICTED with STRONG or MODERATE evidence (`knownWrong`). The mock-based cache experiments in VALIDATION.md have not been rerun since then.
- S1 is incomplete: 22 claims went unchecked when the daily free quota ran out. Its F1 is computed on what it judged.
- The one stale claim S3 missed (Patch Tuesday) was tagged HISTORICAL and skipped. Its 2 false alarms (the Hubble constant, and La Paz as capital) are labelled CONFLICTING, which is arguably a labelling question.

### What a reviewed result needs

1. Two people label `eval/hl-claims/review-sheet.csv` independently. Then compute Cohen's kappa with `eval/hl-claims/review.py`.
2. Then the one test-split run, as a sample that fits the free daily cap.

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

- Any figure as measured on reviewed labels or on the test split.
- That the dev-run F1 difference is significant. The confidence intervals overlap.
- That Halflife detects OUTDATED (once-true) facts on live models. Strict recall is 0.
