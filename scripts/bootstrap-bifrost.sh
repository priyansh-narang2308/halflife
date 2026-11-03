#!/usr/bin/env bash
# Check out the Halflife fork of Bifrost into ./bifrost and verify it against
# the pinned upstream release.
#
# Layout of the resulting repo:
#   halflife  branch = the fork (FORK_URL): a root commit holding the
#             upstream v2.4.0 tree without docs/ (618 MB of media), then our
#             commits (plugin, registration, report endpoint)
#   upstream  branch = the pinned upstream commit, fetched shallow from
#             GitHub, never modified
#
# The root commit is checked tree for tree against upstream: every file
# outside docs/ is upstream's, byte for byte. GitHub rejects pushes from a
# shallow clone and forks of public repos can't be private, which is why the
# fork starts from a snapshot instead of upstream's history.
# Safe to re-run: an existing checkout is verified, never reset.
set -euo pipefail

PIN_TAG="transports/v2.4.0"
PIN_COMMIT="e869c3f9adc96ea53c38694a21bb04a8e1085487"
UPSTREAM_URL="https://github.com/maximhq/bifrost.git"
FORK_URL="${FORK_URL:-https://github.com/priyansh-narang2308/halflife-bifrost.git}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/bifrost"

if [ ! -d "$DEST/.git" ]; then
  git clone --branch halflife "$FORK_URL" "$DEST"
  git -C "$DEST" fetch -q --depth 1 --filter=blob:none "$UPSTREAM_URL" "refs/tags/$PIN_TAG:refs/tags/$PIN_TAG"
  git -C "$DEST" branch upstream "$PIN_COMMIT"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
# without_docs commit -> the hash of its root tree with docs/ removed
without_docs() { git -C "$DEST" ls-tree "$1" | grep -v $'\tdocs$' | git -C "$DEST" mktree; }

tag_commit="$(git -C "$DEST" rev-parse "refs/tags/$PIN_TAG^{commit}")"
upstream_commit="$(git -C "$DEST" rev-parse upstream)"
remote_commit="$(git ls-remote "$UPSTREAM_URL" "refs/tags/$PIN_TAG^{}" | cut -f1)"
[ -n "$remote_commit" ] || remote_commit="$(git ls-remote "$UPSTREAM_URL" "refs/tags/$PIN_TAG" | cut -f1)"
roots="$(git -C "$DEST" rev-list --max-parents=0 halflife)"

[ "$tag_commit" = "$PIN_COMMIT" ]      || fail "local tag $PIN_TAG is $tag_commit, expected $PIN_COMMIT"
[ "$upstream_commit" = "$PIN_COMMIT" ] || fail "upstream branch is $upstream_commit, expected $PIN_COMMIT"
[ "$remote_commit" = "$PIN_COMMIT" ]   || fail "GitHub tag $PIN_TAG is $remote_commit, expected $PIN_COMMIT"
[ "$(echo "$roots" | wc -l | tr -d ' ')" = 1 ] || fail "halflife has more than one root commit"
[ "$(without_docs "$roots")" = "$(without_docs upstream)" ] \
  || fail "halflife's root commit $roots is not upstream $PIN_COMMIT without docs/"

echo "OK  pinned commit  $PIN_COMMIT ($PIN_TAG)"
echo "OK  GitHub tag     $remote_commit"
echo "OK  fork root      $(git -C "$DEST" rev-parse --short "$roots") = upstream tree without docs/"
echo "OK  branches       upstream=$(git -C "$DEST" rev-parse --short upstream) halflife=$(git -C "$DEST" rev-parse --short halflife) (current: $(git -C "$DEST" branch --show-current))"
echo "OK  our commits    $(git -C "$DEST" rev-list --count "$roots"..halflife) on halflife"
