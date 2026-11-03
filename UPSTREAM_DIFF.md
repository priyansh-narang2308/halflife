# Upstream Diff

What we changed in Bifrost, why, and how to check it.

## Base

| | |
|---|---|
| Repository | https://github.com/maximhq/bifrost (Apache-2.0) |
| Tag | `transports/v2.4.0` (annotated tag object `9c6ac22`) |
| Commit | `e869c3f9adc96ea53c38694a21bb04a8e1085487`, 29 Oct 2026, "fix failing tests (#9306)" |
| Fork repository | https://github.com/priyansh-narang2308/halflife-bifrost (private until submission), branch `halflife` |
| Local checkout | `bifrost/`, cloned and verified by `scripts/bootstrap-bifrost.sh` |

## Branches

- `halflife` (the fork repository's default branch):
  - Its root commit `e69be85` is the tree of upstream `e869c3f` without `docs/` (618 MB of media), committed with upstream's author and date and credited to upstream (Apache-2.0).
  - Our commits follow on top of it.
  - `scripts/bootstrap-bifrost.sh` checks that the root's tree, minus `docs/`, is upstream's, hash for hash.
- `upstream`: the pinned commit, fetched shallow from GitHub. Never modified.

The fork can't simply carry upstream's history: the local clone is shallow (GitHub rejects pushes from it), and a GitHub fork of a public repository can't be private. On 3 Nov 2026 our commits were replayed onto the snapshot root with their original authors, dates and messages. Every tree is identical outside `docs/`, but the hashes changed:

| Before | Now |
|---|---|
| `ff8784d` | `cfc3697` |
| `c7c0589` | `e3e1f1c` |
| `749649c` | `b0a1657` |
| `ee3c559` | `2e9a928` |
| `33dfa10` | `6c0b439` |
| `d1c2f45` | `2cb9684` |
| `e79513c` | `12b7583` |
| `2062159` | `92454da` |
| `3118d0c` | `fb5b14c` |
| `b223df2` | `936899a` |
| `8c24ed1` | `08e5596` |
| `1775dc7` | `d9bff71` |
| `f1b6df3` | `9f822eb` |

To see every change we made:

```bash
git -C bifrost diff --stat upstream halflife -- . ':!docs'
```

## Ownership

- **Ours:** everything under `bifrost/plugins/halflife/` (added in fork commit `cfc3697`), plus the files listed under "Modified upstream files". The module path `github.com/maximhq/bifrost/plugins/halflife` is the fork's namespace, not a claim of upstream authorship.

## Added files

| Path | Contents |
|---|---|
| `plugins/halflife/go.mod`, `go.sum` | Own module; requires `core v1.14.1`, `framework v1.11.1` and `semanticcache v1.7.4`, the versions release builds pin, `santhosh-tekuri/jsonschema/v6 v6.0.2` (Apache-2.0), `mattn/go-sqlite3 v1.14.32` (MIT), `golang.org/x/text v0.43.0` and `golang.org/x/net v0.61.0` (BSD-3-Clause): all imported, none copied, each at the version `transports/go.mod` already requires, so the gateway's `go.sum` is unchanged |
| `plugins/halflife/config.go` | `Config`, defaults, validation; `verifiers` maps tenants to verifier keys (D37) |
| `plugins/halflife/main.go` | `Init`, `Cleanup`, the LLM and HTTP transport hooks, recursion guard, `Report` lookup |
| `plugins/halflife/capture.go`, `pool.go`, `links.go` | Answer capture, bounded audit queue, cache entry → report links |
| `plugins/halflife/invalidate.go` | Stale-answer eviction and the write-window bypass |
| `plugins/halflife/tavily.go` | Tavily client that only calls the gateway's relay |
| `plugins/halflife/claim.go`, `verifier.go` | Verifier: the M1 keyword path when no verifier model is configured, else extract → classify → rank → search → judge → strength; searches reused within 10 minutes |
| `plugins/halflife/report.go` | Report type (verdicts, quotes, strength, score) and bounded in-memory store |
| `plugins/halflife/store.go` | Persistent report store: SQLite (`mattn/go-sqlite3`, MIT, the driver the gateway already requires), claim and source provenance rows, retention, versioned migrations |
| `plugins/halflife/llm.go` | Verifier LLM client: structured JSON through the gateway's chat endpoint, schema-validated, one corrective retry |
| `plugins/halflife/extract.go` | Atomic claim extraction: pre-filter, one strict-schema LLM call, span check |
| `plugins/halflife/scope.go` | Temporal scope: the extractor's label confirmed or overruled by cues in the span |
| `plugins/halflife/priority.go` | Verification priority from volatility band and elapsed time; operator-supplied knowledge-cutoff table |
| `plugins/halflife/retrieval.go` | Per-category Tavily Search parameters; when to Extract |
| `plugins/halflife/compare.go` | Typed comparators: versions, prices, names, dates, quantities (`golang.org/x/text` for accent folding, already in the gateway's build) |
| `plugins/halflife/judge.go` | Judge call, verbatim quote verification, deterministic verdict rules |
| `plugins/halflife/strength.go` | Evidence strength and freshness score (`golang.org/x/net/publicsuffix`, already in the gateway's build) |
| `plugins/halflife/testdata/claims/*.json` | Synthetic extraction fixtures (fictional companies) |
| `plugins/halflife/*_test.go`, `version` | Unit tests; version `0.1.0` |
| `transports/bifrost-http/handlers/halflife.go`, `halflife_test.go` | `GET /api/halflife/reports/{id}`, resolving the plugin per request like the cache handler |
- **Upstream:** everything else, unchanged.

## Modified upstream files (v1)

Four upstream files, nothing removed or rewritten: three in fork commit `e3e1f1c` (extended in Task 19), `server.go` in Task 25.

| File | Change | Why |
|---|---|---|
| `transports/bifrost-http/server/plugins.go` | +1 import; +19 lines: a `halflife` case in `loadBuiltinPlugin` (same pattern as `semanticcache`), which also gives Halflife a cache evictor that looks up the `semantic_cache` plugin at eviction time (`lib.FindPluginAs`) and calls its existing `ClearCacheForCacheID` (Task 19); +11 lines: block 11 in `loadBuiltinPlugins`, which registers Halflife only when enabled in `plugins` and sets placement `pre_builtin`, order `math.MinInt` | The evictor is the only way to delete a cache entry by ID from outside the cache plugin; the lookup is lazy because the cache can be loaded, reloaded or removed after Halflife. Release binaries are static, so plugins can't be loaded as `.so` files; built-ins are compiled in here. The placement puts Halflife first in pre-hooks and **last** in post-hooks, so it sees the final response (verified from the gateway's debug log, Task 09). |
| `transports/bifrost-http/lib/config.go` | +1 import; `halflife.PluginName` appended to `builtinPluginNames` | That list is the single source of truth for built-ins. Being in it stops the custom-plugin loader from loading Halflife a second time, and keeps its fixed placement from being overridden by config. |
| `transports/bifrost-http/server/server.go` | +1 import; +8 lines building the Halflife handler (plugin looked up per request with `lib.FindPluginAs`, as for the cache handler); +1 line registering its routes with the same middlewares as every `/api` route | Plugins can't add HTTP routes. Sharing the middlewares means the reports endpoint gets the same dashboard auth as the rest of `/api`. |
| `transports/go.mod` | `require …/plugins/halflife v0.1.0` + `replace … => ../plugins/halflife` | Release builds run with `GOWORK=off` and resolve published versions; the local module needs an explicit `replace`. `go.sum` unchanged: the plugin adds no dependency the gateway didn't already have (its JSON Schema validator is the gateway's own `jsonschema/v6 v6.0.2`). |

## Checks after the change

- `GOWORK=off go build ./...` and `go vet` in `transports/` succeed. `go version -m` on the binary shows `github.com/maximhq/bifrost/plugins/halflife v0.1.0 => ../plugins/halflife`.
- Upstream tests in `transports/bifrost-http/server` and `.../lib` pass when run with a clean environment. In a shell that exports `ANTHROPIC_API_KEY`, 5 `lib` tests fail with "expected 1 keys for provider anthropic, got 2". That's Bifrost's provider auto-detection reading the shell (D7), and it's unrelated to Halflife.
- `gofmt -l` flags `lib/config.go` at line ~6825. That's upstream code, unformatted before our change; we leave it as is.

## Compatibility

- Dependencies stay as pinned by upstream `go.mod` files. We don't bump core, framework or plugin versions.
- `docs/` is excluded from the checkout via sparse checkout. This only skips writing files to disk; the commits are identical to upstream.
