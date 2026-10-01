#!/usr/bin/env bash
#
# Swap every held formula in the local homebrew/core checkout for upstream's version, so
# this job plans, builds and publishes the version upstream has moved on to.
#
# The fork holds a formula at its bottled version when upstream bumps it (see
# apply_manifest.py), so the Intel Mac never sees a version it would have to compile.
# But the fork is also what CI plans from, and there the held version looks bottled --
# so nothing ever built the new one, and holds became permanent. openssl@3, node, gh and
# 25 more were stuck for weeks. sync_fork.sh therefore records each hold in
# .intel-bottles-holds at the fork's root, and CI jobs call this after `brew update`.
#
# The swap only touches the runner's working tree. publish.sh commits it for formulae it
# actually published and reverts the rest, so the fork still never offers a version
# without a bottle.
#
# Holds file, tab-separated: name, path, upstream commit, held version, upstream version.

set -euo pipefail

CORE_REPO="${CORE_REPO:-$(brew --repo homebrew/core)}"
HOLDS="$CORE_REPO/.intel-bottles-holds"
UPSTREAM_RAW="${UPSTREAM_RAW:-https://raw.githubusercontent.com/Homebrew/homebrew-core}"

if [ ! -s "$HOLDS" ]; then
  echo "==> no held formulae"
  exit 0
fi

echo "==> using upstream's version of held formulae"
while IFS=$'\t' read -r name path revision held upstream; do
  case "$name" in '' | '#'*) continue ;; esac
  tmp="$(mktemp)"
  if curl -fsSL --retry 3 --retry-delay 5 "$UPSTREAM_RAW/$revision/$path" -o "$tmp"; then
    mv "$tmp" "$CORE_REPO/$path"
    echo "    $name: $held -> $upstream"
  else
    rm -f "$tmp"
    echo "    WARNING: could not fetch upstream $path; $name stays at $held" >&2
  fi
done < "$HOLDS"
