# Demo script (about 3 minutes)

Runs on the mock stack, so it is repeatable and free. Say that it is mocks. Then show one live result from `testenv/results/` if a real run is wanted on screen.

**Setup.** `docker compose --profile demo up --build`, the dashboard open at `/workspace/halflife`, a terminal beside it.

| Time | Show | Say |
| --- | --- | --- |
| 0:00 | Slide or README first paragraph | LLM answers go stale silently, and semantic caches repeat them. |
| 0:20 | `./deploy/demo.sh`, the first request | The app talks to Bifrost as usual. It got an answer straight away; the response carries a report ID. Note the first user still gets the stale answer in audit mode. |
| 0:50 | The audit output | Off the request path, Halflife extracted the claim, searched through a governed Tavily relay, and quoted the evidence. |
| 1:20 | The second request in the script | Same question: the stale answer is gone from the cache, so it goes to the model again, and `X-Halflife-Status: known-outdated` flags it. The mock repeats its scripted text; say so. |
| 1:40 | Dashboard, Halflife page; open the report | Claims, verdicts, sources, cost per tenant, cache events, inside Bifrost's own UI. |
| 2:10 | Tenants table; `make tenants` result in VALIDATION.md | Each tenant's verification runs on its own verifier key, so Bifrost's budgets apply. |
| 2:30 | EVALUATION.md | What was measured, and what was not. |
| 2:50 | ARCHITECTURE.md diagram | A plugin in the gateway, about 66 µs on the request path. |

Do not claim anything from the evaluation beyond what EVALUATION.md states.
