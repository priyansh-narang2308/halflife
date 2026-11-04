# Halflife

A Bifrost gateway plugin that catches stale facts in LLM answers. Models answer confidently from whatever they learned; semantic caches then repeat those answers. Halflife audits answers as they pass through the gateway: it extracts the claims, checks the time-sensitive ones against live sources through Tavily, reports a verdict with quoted evidence, evicts stale answers from the semantic cache, and attributes every cent of verification to the tenant that caused it.

Built for the Geek Room Global AI Hackathon 2026 (Bifrost and Tavily tracks).

It is a gateway extension, not a fact-checking site: apps change nothing but their base URL, and verification adds a median of about 66 µs to the request path at concurrency 1 (216 µs at concurrency 16; `make bench`, against a mock upstream).

## Try it

The demo stack needs only Docker. Its LLM and Tavily are mocks with scripted answers, and it makes no external call.

```bash
docker compose --profile demo up --build
```

```bash
./deploy/demo.sh
```

Then open the dashboard at <http://localhost:8080/workspace/halflife>.

With real providers, put `OPENROUTER_API_KEY` and `TAVILY_API_KEY` in `.env` (see `.env.example`) and point the stack at the live config. It uses free models, and has no semantic cache because it has no embedding provider configured.

```bash
HALFLIFE_CONFIG=./deploy/live/config.json docker compose up --build
```

The keys and setup token in `deploy/` are synthetic. Replace them before exposing the gateway.

## Why a gateway

| Bifrost gives Halflife | Tavily gives Halflife |
| --- | --- |
| Every answer, from every app, with no client change | Search built for agents, with dates and scores for recency |
| The semantic cache, the place stale answers get repeated from | Extract, to read a source when a snippet falls short |
| Virtual keys, budgets and relays, so each tenant's verification is capped and attributed | Credit usage in every reply, reconciled against what Bifrost charged |

## What was verified

[VALIDATION.md](VALIDATION.md) records the command, output and live-or-mock status of every check. `make test` runs the unit tests; `make smoke cache relay budget tenants verify m1 llm claims failures operator experiments` run the suites through a real gateway against mocks. [EVALUATION.md](EVALUATION.md) has the accuracy evaluation and its limits, which you should read before quoting any number from it.

## Repository

- `bifrost/`: the fork ([halflife-bifrost](https://github.com/priyansh-narang2308/halflife-bifrost)); the plugin is `plugins/halflife`, the dashboard page `ui/app/workspace/halflife`. Set it up with `scripts/bootstrap-bifrost.sh`
- `ARCHITECTURE.md`: how it works
- `EVALUATION.md`: methods, numbers, limitations
- `DEMO.md`: the demo script
- `SUBMISSION.md`: the submission checklist and AI-use disclosure
- `UPSTREAM_DIFF.md`: every change made to Bifrost, and why
- `TASKS.md`, `PROGRESS.md`, `VALIDATION.md`: the plan, the decisions, the evidence
- `eval/`: the HL-Claims dataset, the replay harness and the scorer
- `testenv/`: mock LLM, mock Tavily, the recording proxy and the suites
- `deploy/`, `docker-compose.yml`: the stack
- `research/`: the strategy report and engineering audit

## License

Bifrost is Apache-2.0; the fork keeps its license and notices ([bifrost/LICENSE](bifrost/LICENSE)). Halflife's plugin code is in that fork under the same license.
