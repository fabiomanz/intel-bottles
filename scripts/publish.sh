#!/usr/bin/env bash
#
# Publish a stage's bottles: merge the DSL into the homebrew-core fork, then upload the
# tarballs as release assets.
#
# Filename gotcha (Homebrew/Library/Homebrew/bottle.rb):
#   Filename#to_s      -> "name--version.tag.bottle.tar.gz"   (what brew bottle writes)
#   Filename#url_encode-> "name-version.tag.bottle.tar.gz"    (what brew fetches from a
#                                                              plain root_url)
# So assets must be uploaded with a SINGLE dash. Only ghcr.io root_urls use the double-dash
# form, and we publish to GitHub Releases.

set -euo pipefail

: "${BOTTLE_DIR:?BOTTLE_DIR must be set}"
: "${RELEASE_TAG:?RELEASE_TAG must be set}"
: "${BOTTLES_REPO:?BOTTLES_REPO must be set}"
: "${STAGE:=bottles}"

cd "$BOTTLE_DIR"

if ! ls ./*.bottle.json >/dev/null 2>&1; then
  echo "==> no bottles produced in this stage, nothing to publish"
  exit 0
fi

# 1. Merge the bottle blocks into the fork FIRST -- brew validates against the JSON while
#    the tarballs still have their original names.
CORE_REPO="$(brew --repo homebrew/core)"
echo "==> merging bottle DSL into $CORE_REPO"
brew bottle --merge --write --no-commit ./*.bottle.json

# 2. Rename to the URL form brew will actually request.
for bottle in ./*.bottle.tar.gz; do
  url_name="$(basename "$bottle" | sed 's/--/-/')"
  if [ "$(basename "$bottle")" != "$url_name" ]; then
    mv "$bottle" "./$url_name"
  fi
done

# 3. Publish the tarballs.
if ! gh release view "$RELEASE_TAG" -R "$BOTTLES_REPO" >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" -R "$BOTTLES_REPO" \
    --title "Intel (x86_64) bottles" \
    --notes "Rolling release of macOS Intel bottles. Managed by CI; do not delete."
fi
echo "==> uploading $(ls ./*.bottle.tar.gz | wc -l | tr -d ' ') asset(s) to $BOTTLES_REPO@$RELEASE_TAG"
gh release upload "$RELEASE_TAG" ./*.bottle.tar.gz --clobber -R "$BOTTLES_REPO"

# 4. Commit the formula changes in the fork.
cd "$CORE_REPO"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Intel bottles: $STAGE ($(date -u +%Y-%m-%d))"
  git push origin HEAD:main
  echo "==> pushed bottle blocks to the fork"
else
  echo "==> fork unchanged"
fi
