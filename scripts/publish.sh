#!/usr/bin/env bash
#
# Publish a stage's bottles: merge the DSL into the homebrew-core fork, then upload the
# tarballs as release assets.
#
# Every (json, tarball) pair is verified before publishing. Bottles are not byte-reproducible,
# so when several jobs build the same shared dependency -- go is a build dep of gh, git-lfs,
# glab, rclone and more -- each produces a different tarball under the SAME filename. Merging
# those artifacts into one directory let `gh release upload --clobber` publish one build while
# `brew bottle --merge` recorded another's checksum, and the formula then failed to install
# with "Bottle reports different checksum". That corrupted 5 of the first 40 bottles.
#
# Artifacts are therefore downloaded unmerged (one directory per job) and reconciled here:
# a pair is published only if the tarball hashes to what its JSON claims, and a duplicate
# bottle keeps whichever verified copy is seen first.
#
# Filename gotcha (Homebrew/Library/Homebrew/bottle.rb):
#   Filename#to_s       -> "name--version.tag.bottle.tar.gz"  (what brew bottle writes)
#   Filename#url_encode -> "name-version.tag.bottle.tar.gz"   (what brew fetches)
# so assets upload with a SINGLE dash.

set -euo pipefail

: "${BOTTLE_DIR:?BOTTLE_DIR must be set}"
: "${RELEASE_TAG:?RELEASE_TAG must be set}"
: "${BOTTLES_REPO:?BOTTLES_REPO must be set}"
: "${STAGE:=bottles}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Network steps get a few attempts. This job runs once per stage, after hours of builds,
# and a single API hiccup here throws all of that away: the next stage then rebuilds
# everything this one produced.
retry() {
  local attempt
  for attempt in 1 2 3 4; do
    "$@" && return 0
    [ "$attempt" -lt 4 ] || break
    echo "    attempt $attempt of '$*' failed; retrying in $((attempt * 20))s" >&2
    sleep $((attempt * 20))
  done
  return 1
}

STAGING="$BOTTLE_DIR/.staged"
rm -rf "$STAGING"
mkdir -p "$STAGING"

shopt -s nullglob
kept=0
skipped=0

for json in "$BOTTLE_DIR"/*.bottle.json "$BOTTLE_DIR"/*/*.bottle.json; do
  base="$(basename "$json" .json)"
  tarball="$(dirname "$json")/${base}.tar.gz"

  if [ ! -f "$tarball" ]; then
    echo "==> $base: no tarball beside the json, skipping" >&2
    skipped=$((skipped + 1))
    continue
  fi

  expected="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(next(iter(next(iter(d.values()))["bottle"]["tags"].values()))["sha256"])
' "$json")"
  actual="$(shasum -a 256 "$tarball" | cut -d" " -f1)"

  if [ "$expected" != "$actual" ]; then
    echo "==> $base: checksum mismatch (json=$expected file=$actual), refusing to publish" >&2
    skipped=$((skipped + 1))
    continue
  fi

  if [ -e "$STAGING/$(basename "$tarball")" ]; then
    echo "==> $base: duplicate build from another job, keeping the first verified copy"
    continue
  fi

  cp "$json" "$tarball" "$STAGING/"
  kept=$((kept + 1))
done

echo "==> $kept bottle(s) verified, $skipped skipped"

# The job downloads every stage's artifacts so it can pick up a stage whose own publish
# never ran; drop whatever is already released or no longer matches the fork.
python3 "$SCRIPT_DIR/drop_published.py" "$STAGING"
kept="$(find "$STAGING" -maxdepth 1 -name '*.bottle.json' | wc -l | tr -d ' ')"
echo "==> $kept bottle(s) to publish"
if [ "$kept" -eq 0 ]; then
  echo "==> nothing to publish"
  exit 0
fi

cd "$STAGING"

# Merge the bottle blocks into the fork first, while the tarballs still have their
# original names (brew validates against the json).
CORE_REPO="$(brew --repo homebrew/core)"
echo "==> merging bottle DSL into $CORE_REPO"
# `brew bottle --merge` installs its gems from rubygems.org on first use, with no retry
# of its own. Install them up front so a DNS blip cannot fail the merge.
retry brew install-bundler-gems --add-groups=ast || true
brew bottle --merge --write --no-commit ./*.bottle.json

for bottle in ./*.bottle.tar.gz; do
  url_name="$(basename "$bottle" | sed 's/--/-/')"
  if [ "$(basename "$bottle")" != "$url_name" ]; then
    mv "$bottle" "./$url_name"
  fi
done

# A failed `view` is not proof the release is missing. On 2026-09-30 a transient API error
# made this branch try to create a release that existed, the 422 aborted the job, and
# wave 1's bottles were never uploaded. Creating is idempotent here: if it fails, the
# release has to be visible afterwards, or this really is an error.
ensure_release() {
  gh release view "$RELEASE_TAG" -R "$BOTTLES_REPO" >/dev/null 2>&1 && return 0
  gh release create "$RELEASE_TAG" -R "$BOTTLES_REPO" \
    --title "Intel (x86_64) bottles" \
    --notes "Rolling release of macOS Intel bottles. Managed by CI; do not delete." \
    && return 0
  gh release view "$RELEASE_TAG" -R "$BOTTLES_REPO" >/dev/null
}
retry ensure_release
echo "==> uploading $(ls ./*.bottle.tar.gz | wc -l | tr -d " ") asset(s)"
retry gh release upload "$RELEASE_TAG" ./*.bottle.tar.gz --clobber -R "$BOTTLES_REPO"

cd "$CORE_REPO"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Intel bottles: $STAGE ($(date -u +%Y-%m-%d))"
  # The sync job may have pushed meanwhile; rebase onto it rather than fail. A conflict
  # means upstream moved a formula we just bottled -- abort and fail, as before.
  push_fork() {
    if ! git pull --rebase --quiet origin main; then
      git rebase --abort 2>/dev/null || true
      return 1
    fi
    git push origin HEAD:main
  }
  retry push_fork
  echo "==> pushed bottle blocks to the fork"
else
  echo "==> fork unchanged"
fi
