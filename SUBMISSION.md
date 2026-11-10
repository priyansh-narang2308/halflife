# Submission checklist

Deadline: 15 Nov 2026, 23:59 IST, on HackCulture. Judging: 29 Nov. Confirm the time zone on the event page.

| Item | State |
| --- | --- |
| Source repository | Done: github.com/priyansh-narang2308/halflife and the fork github.com/priyansh-narang2308/halflife-bifrost. Both must be public on the day |
| Project description and problem statement | Done: README |
| Technologies | Done: Go, Bifrost plugin API, Tavily Search and Extract, Redis, React, TanStack Router, Docker |
| Working demo | Done: docker-compose.yml, and `deploy/share.sh` for a public link while your laptop runs it. Run it for the live round on 29 Nov |
| Demo video | Script done: DEMO.md. Needs recording |
| Evaluation | Dev run done on free models (F1 0.77 vs 0.53 baseline, draft labels): see EVALUATION.md. Human labels, Cohen's kappa and the held-out run are outstanding |
| AI-use disclosure | Draft below; review it, then include it |
| Submit on HackCulture | Yours to do |

## Text to paste

**Project name.** Halflife

**Tagline.** A Bifrost gateway plugin that catches stale facts in LLM answers and evicts them from the semantic cache.

**Problem.** LLMs answer confidently from training data that goes out of date: prices, office holders, version numbers, rules. A semantic cache makes this worse, because it keeps serving the old answer to every user who asks. Most apps have no check between the model and the user. And when teams add one, nobody can say which tenant the verification cost belongs to.

**Solution.** Halflife runs inside the Bifrost gateway, so apps only change their base URL. For each answer it extracts the claims and scores how time-sensitive each one is. It checks the risky claims with Tavily Search and Extract, through governed Bifrost relays. An LLM judge reads the evidence and gives a verdict (current, outdated, contradicted, conflicting, unverifiable), and every verdict must quote its source. Answers it finds stale are evicted from the semantic cache, or flagged in monitor mode. Each verification call goes through the tenant's own virtual key and budget, so the spend is capped and attributed per tenant. A dashboard inside the Bifrost UI shows the reports and their evidence.

**Tracks.** Bifrost #04, a feature the open-source gateway is missing: answer-freshness auditing and cache eviction. Tavily #01, a stale-answer detector. It is one project that answers both.

**Results.** Halflife adds about 66 µs to the request path (median, concurrency 1). In the cache experiments, 0 of 40 outdated answers were served from the cache in audit mode, against 40 of 40 without Halflife (with mock verdicts). On 42 dev claims checked with live Tavily and free models, it scored a stale-answer F1 of 0.77, against 0.53 for a simple baseline, using 18 Tavily credits instead of 38. The labels are drafts and the sample is small; EVALUATION.md has the limits. Plugin test coverage is 96.1%.

**Technologies.** Go, Bifrost v2.4.0 plugin API, Tavily Search and Extract, OpenRouter free models, Redis, React, TanStack Router, Docker Compose.

**How AI is used.** At run time, LLMs extract claims from answers and judge them against Tavily evidence. Code checks that each quoted span appears in the source and contains the value it cites.

## AI-use disclosure (draft)

This project was built with AI assistance. Claude Code wrote most of the code, tests and documentation under the author's direction, and the author reviewed the plan and results. At run time the product uses LLMs to extract claims and judge evidence. Draft labels in the HL-Claims dataset were proposed by a script and must be reviewed by humans; EVALUATION.md states which results rest on draft labels.
