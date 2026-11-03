# Upstream Diff

What we changed in Bifrost, why, and how to check it.

## Base

| | |
|---|---|
| Repository | https://github.com/maximhq/bifrost (Apache-2.0) |
| Tag | `transports/v2.4.0` (annotated tag object `9c6ac22`) |
| Commit | `e869c3f9adc96ea53c38694a21bb04a8e1085487`, 29 Oct 2026, "fix failing tests (#9306)" |
| Local checkout | `bifrost/`, created and verified by `scripts/bootstrap-bifrost.sh` |

## Branches

- `upstream`: the pinned commit. Never modified.
- `halflife`: `upstream` plus our commits.

To see every change we made:

```bash
git -C bifrost diff --stat upstream..halflife
```

## Ownership

- **Ours:** everything under `bifrost/plugins/halflife/` (added in fork commit `ff8784d`), plus the files listed under "Modified upstream files". The module path `github.com/maximhq/bifrost/plugins/halflife` is the fork's namespace, not a claim of upstream authorship.

## Added files

| Path | Contents |
|---|---|
| `plugins/halflife/go.mod`, `go.sum` | Own module; requires only `core v1.14.1`, the version release builds pin |
| `plugins/halflife/config.go` | `Config` (`queue_size`, `workers`, `max_claims_per_response`, `tavily_relay`), defaults, validation |
| `plugins/halflife/main.go` | `Init`, `GetName`, `Cleanup`, pass-through LLM and HTTP transport hooks |
| `plugins/halflife/*_test.go`, `version` | Unit tests; version `0.1.0` |
- **Upstream:** everything else, unchanged.

## Modified upstream files (v1)

Three upstream files, 24 added lines, nothing removed or rewritten (fork commit `c7c0589`).

| File | Change | Why |
|---|---|---|
| `transports/bifrost-http/server/plugins.go` | +1 import; +19 lines: a `halflife` case in `loadBuiltinPlugin` (same pattern as `semanticcache`), which also gives Halflife a cache evictor that looks up the `semantic_cache` plugin at eviction time (`lib.FindPluginAs`) and calls its existing `ClearCacheForCacheID` (Task 19); +11 lines: block 11 in `loadBuiltinPlugins`, which registers Halflife only when enabled in `plugins` and sets placement `pre_builtin`, order `math.MinInt` | The evictor is the only way to delete a cache entry by ID from outside the cache plugin; the lookup is lazy because the cache can be loaded, reloaded or removed after Halflife. Release binaries are static, so plugins can't be loaded as `.so` files; built-ins are compiled in here. The placement puts Halflife first in pre-hooks and **last** in post-hooks, so it sees the final response (verified from the gateway's debug log, Task 09). |
| `transports/bifrost-http/lib/config.go` | +1 import; `halflife.PluginName` appended to `builtinPluginNames` | That list is the single source of truth for built-ins. Being in it stops the custom-plugin loader from loading Halflife a second time, and keeps its fixed placement from being overridden by config. |
| `transports/go.mod` | `require …/plugins/halflife v0.1.0` + `replace … => ../plugins/halflife` | Release builds run with `GOWORK=off` and resolve published versions; the local module needs an explicit `replace`. `go.sum` unchanged: the plugin adds no dependency the gateway didn't already have. |

Planned:

| File | Planned change | Why |
|---|---|---|
| `transports/bifrost-http/handlers/` (Task 25) | Add a report endpoint handler | Plugins can't add HTTP routes |

## Checks after the change

- `GOWORK=off go build ./...` and `go vet` in `transports/` succeed. `go version -m` on the binary shows `github.com/maximhq/bifrost/plugins/halflife v0.1.0 => ../plugins/halflife`.
- Upstream tests in `transports/bifrost-http/server` and `.../lib` pass when run with a clean environment. In a shell that exports `ANTHROPIC_API_KEY`, 5 `lib` tests fail with "expected 1 keys for provider anthropic, got 2". That's Bifrost's provider auto-detection reading the shell (D7), and it's unrelated to Halflife.
- `gofmt -l` flags `lib/config.go` at line ~6825. That's upstream code, unformatted before our change; we leave it as is.

## Compatibility

- Dependencies stay as pinned by upstream `go.mod` files. We don't bump core, framework or plugin versions.
- `docs/` is excluded from the checkout via sparse checkout. This only skips writing files to disk; the commits are identical to upstream.
