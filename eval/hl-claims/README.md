# HL-Claims v1

240 atomic claims for evaluating Halflife's verdicts, with a dev/test split frozen
before any tuning. Snapshot date: 2026-11-04.

**The labels are drafts.** `expected_verdict` is set by rule from how each claim
was built. No person has reviewed it, so nothing measured against this file is a
result yet. Every claim has `label_status: draft_pending_review`, and there is no
inter-rater agreement figure because no second labeller has labelled anything.

| Stratum | Claims (dev / test) | Built from | Draft verdict |
|---|---|---|---|
| `recently_changed` | 60 (24 / 36) | FreshQA answers that differ between the 2024-02-26 and 2026-04-21 snapshots | OUTDATED |
| `stable` | 40 (16 / 24) | FreshQA never-changing questions | CURRENT |
| `historical` | 30 (12 / 18) | Other changed FreshQA answers, scoped "As of February 2024" | CURRENT |
| `never_true` | 30 (12 / 18) | Never-changing answers with one number altered by `build.py` | CONTRADICTED |
| `conflicting` | 20 (8 / 12) | `curated-conflicting.json`: disputed facts | CONFLICTING |
| `ambiguous` | 30 (12 / 18) | FreshQA answers with the subject removed | UNVERIFIABLE |
| `unverifiable` | 30 (12 / 18) | Private facts about invented companies | UNVERIFIABLE |

`recencyqa-sample.jsonl` is separate: 400 RecencyQA questions with their class
collapsed to Halflife's five bands, for evaluating the volatility classifier only.
RecencyQA's labels are LLM-generated, with 76% reported human agreement.

## Known limits

- FreshQA's latest snapshot is six months older than ours. A `recently_changed`
  answer may have changed again, and each needs re-verifying as of the snapshot.
- FreshQA diffs include rewordings and "this year"-style questions whose answer
  moves by itself. Reviewers should relabel or drop these.
- The conflicting set was written from general knowledge. Its URLs were checked to
  load (all 200 on 2026-11-04), but their content wasn't read against each claim.
- The audit also planned curated changes from Jan–Oct 2026, and HL-Answers. Neither
  is here: the FreshQA diffs alone filled the stratum, and HL-Answers needs real
  model answers.

## The review

1. Two people who didn't write the prompts each fill in a copy of
   `review-sheet.csv`, independently. It shows no draft label or stratum. `label`
   is one of CURRENT, OUTDATED, CONTRADICTED, CONFLICTING or UNVERIFIABLE, and
   `evidence_url` and `evidence_date` say what it rests on.
2. `python3 review.py a.csv b.csv` prints Cohen's kappa and the disagreements.
3. A third person decides those; `python3 review.py a.csv b.csv c.csv` writes
   `final-labels.csv`.

Corrections change labels, not the split: a dropped claim stays out of both sides.

## Rebuilding

`make dataset` rebuilds from `data/hl-claims-sources` and fails if the sources or
the split differ from `MANIFEST.json`, which freezes both by hash. `fetch.sh`
downloads the sources. Nothing tuned Halflife against the test split, and nothing
should until the single test run in audit §6.

## Sources

- FreshQA: Vu et al., *FreshLLMs*, [arXiv:2310.03214](https://arxiv.org/abs/2310.03214).
  The repo's code is Apache-2.0; its sheets state no licence, so the raw sheets are
  not committed. Check their terms before making this dataset public.
- RecencyQA: [DataScienceUIBK/RecencyQA](https://github.com/DataScienceUIBK/RecencyQA)
  at `21b0c3b`, MIT licence. Its questions in `recencyqa-sample.jsonl` keep that licence.
