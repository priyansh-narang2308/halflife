#!/usr/bin/env bash
# Check out the pinned Bifrost source into ./bifrost and verify it.
#
# Layout of the resulting repo:
#   upstream  branch = the pinned upstream commit, never modified
#   halflife  branch = upstream + our commits (plugin and minimal registration)
#
# docs/ (618 MB of media) is excluded via sparse checkout. This only skips
# writing those files to disk; commits and diffs are identical to upstream.
# Safe to re-run: an existing checkout is verified, never reset.
set -euo pipefail

PIN_TAG="transports/v2.4.0"
PIN_COMMIT="e869c3f9adc96ea53c38694a21bb04a8e1085487"
REPO_URL="https://github.com/maximhq/bifrost.git"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/bifrost"

if [ ! -d "$DEST/.git" ]; then
  git clone --filter=blob:none --no-checkout --depth 1 --branch "$PIN_TAG" "$REPO_URL" "$DEST"
  git -C "$DEST" sparse-checkout set --no-cone '/*' '!/docs/'
  git -C "$DEST" checkout -q -b upstream "$PIN_COMMIT"
  git -C "$DEST" branch halflife upstream
  git -C "$DEST" checkout -q halflife
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

tag_commit="$(git -C "$DEST" rev-parse "refs/tags/$PIN_TAG^{commit}")"
upstream_commit="$(git -C "$DEST" rev-parse upstream)"
remote_commit="$(git -C "$DEST" ls-remote origin "refs/tags/$PIN_TAG^{}" | cut -f1)"
[ -n "$remote_commit" ] || remote_commit="$(git -C "$DEST" ls-remote origin "refs/tags/$PIN_TAG" | cut -f1)"

[ "$tag_commit" = "$PIN_COMMIT" ]      || fail "local tag $PIN_TAG is $tag_commit, expected $PIN_COMMIT"
[ "$upstream_commit" = "$PIN_COMMIT" ] || fail "upstream branch is $upstream_commit, expected $PIN_COMMIT"
[ "$remote_commit" = "$PIN_COMMIT" ]   || fail "GitHub tag $PIN_TAG is $remote_commit, expected $PIN_COMMIT"
git -C "$DEST" merge-base --is-ancestor upstream halflife || fail "halflife does not descend from upstream"

echo "OK  pinned commit  $PIN_COMMIT ($PIN_TAG)"
echo "OK  GitHub tag     $remote_commit"
echo "OK  branches       upstream=$(git -C "$DEST" rev-parse --short upstream) halflife=$(git -C "$DEST" rev-parse --short halflife) (current: $(git -C "$DEST" branch --show-current))"
echo "OK  our commits    $(git -C "$DEST" rev-list --count upstream..halflife) on halflife"
