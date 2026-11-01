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

- **Ours:** everything under `bifrost/plugins/halflife/` (from Task 07), plus the files listed under "Modified upstream files".
- **Upstream:** everything else, unchanged.

## Modified upstream files

None yet (Task 03). Planned for Task 08, kept minimal:

| File | Planned change | Why |
|---|---|---|
| `transports/bifrost-http/server/plugins.go` | Register Halflife as a built-in plugin | Release binaries are static, so plugins can't be loaded as `.so` files; built-ins must be compiled in through this file |
| `transports/go.mod`, `transports/go.sum` | `require` + `replace` for the local plugin module | Release builds run with `GOWORK=off` and resolve published module versions; a local module needs an explicit `replace` |
| `transports/bifrost-http/handlers/` (Task 25) | Add a report endpoint handler | Plugins can't add HTTP routes |

## Compatibility

- Dependencies stay as pinned by upstream `go.mod` files. We don't bump core, framework or plugin versions.
- `docs/` is excluded from the checkout via sparse checkout. This only skips writing files to disk; the commits are identical to upstream.
