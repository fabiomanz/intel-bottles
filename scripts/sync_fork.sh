#!/usr/bin/env bash
#
# Rebuild the homebrew-core fork as: upstream + our bottle blocks.
#
# The fork is never hand-edited and never merged -- it is hard-reset onto upstream and our
# blocks are re-applied from manifest/. That makes merge conflicts structurally impossible,
# and it means a formula whose version upstream has bumped silently loses our (now stale)
# bottle and reappears in the next build plan.

set -euo pipefail

: "${FORK_REPO:?FORK_REPO must be set}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_REPO="$(brew --repo homebrew/core)"

echo "==> resetting $CORE_REPO onto upstream"
cd "$CORE_REPO"
git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream https://github.com/Homebrew/homebrew-core.git
git fetch --quiet upstream main
git reset --hard upstream/main

echo "==> re-applying bottle blocks"
cd "$REPO_DIR"
APPLICABLE="$(python3 scripts/apply_manifest.py)"

if [ -n "$APPLICABLE" ]; then
  # shellcheck disable=SC2086 -- paths are ours and contain no whitespace
  brew bottle --merge --write --no-commit $APPLICABLE
else
  echo "no applicable bottle blocks"
fi

cd "$CORE_REPO"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Re-apply Intel bottle blocks ($(date -u +%Y-%m-%d))"
fi

echo "==> force-pushing the rebuilt fork"
git push --force origin HEAD:main
