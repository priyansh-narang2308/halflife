# Halflife

A Bifrost gateway plugin that catches stale facts in LLM answers. It re-verifies time-sensitive claims against live sources via Tavily, attributes the verification spend to Bifrost budgets, and keeps the gateway's semantic cache from serving answers it has found to be outdated.

Built for the Geek Room Global AI Hackathon 2026 (Bifrost #04 + Tavily #01).

Status: early engineering. See [TASKS.md](TASKS.md) for the plan and [PROGRESS.md](PROGRESS.md) for where things stand.

## Repository

- `research/`: strategy report and engineering audit (pre-build research)
- `TASKS.md`: the 50-task plan
- `PROGRESS.md`: completed work, decisions, blockers
- `VALIDATION.md`: commands, outputs, and live-vs-mock status for every test
- `.env.example`: every key the project needs; copy to `.env` (gitignored)
- `UPSTREAM_DIFF.md`: every change made to Bifrost, and why
- `scripts/bootstrap-bifrost.sh`: checks out and verifies the pinned Bifrost source into `bifrost/`
- `scripts/build-gateway.sh`: builds the dashboard and `bifrost/tmp/bifrost-http` the way upstream does
- `scripts/run-gateway.sh`: runs the gateway on 127.0.0.1:8090 with only `.env` credentials visible
