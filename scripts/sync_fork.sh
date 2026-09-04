#!/usr/bin/env bash
#
# Rebuild the homebrew-core fork as: upstream, held back to versions we have bottles for.
#
# The fork is never hand-edited and never merged -- it is hard-reset onto upstream and the
# plan from apply_manifest.py is replayed on top, so merge conflicts cannot happen.
#
# The hold is the point: if we let a formula advance to a version we have no bottle for,
# the next `brew upgrade` on the local machine compiles it from source. Holding it at the
# bottled version means the machine only ever sees versions it can pour, and picks up the
# new one within a day, once CI has built a bottle.

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

echo "==> planning"
cd "$REPO_DIR"
PLAN="$(python3 scripts/apply_manifest.py)"

if [ -z "$PLAN" ]; then
  echo "nothing in the manifest to apply"
else
  # Restores first: put held formulae back to the revision we bottled.
  echo "$PLAN" | grep '^RESTORE' | while IFS=$'\t' read -r _ revision path name from to; do
    echo "    holding $name at $from (upstream $to)"
    if ! git -C "$CORE_REPO" checkout "$revision" -- "$path" 2>/dev/null; then
      # The clone may not have that object (shallow, or an upstream force-push).
      git -C "$CORE_REPO" fetch --quiet upstream "$revision" 2>/dev/null || true
      git -C "$CORE_REPO" checkout "$revision" -- "$path" \
        || echo "    WARNING: could not restore $name at $from; it will build from source" >&2
    fi
  done

  JSONS="$(echo "$PLAN" | grep '^APPLY' | cut -f2 | tr '\n' ' ')"
  if [ -n "${JSONS// /}" ]; then
    echo "==> re-applying bottle blocks"
    # shellcheck disable=SC2086 -- our own paths, no whitespace
    brew bottle --merge --write --no-commit $JSONS
  fi
fi

cd "$CORE_REPO"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Re-apply Intel bottle blocks ($(date -u +%Y-%m-%d))"
fi

echo "==> force-pushing the rebuilt fork"
git push --force origin HEAD:main
