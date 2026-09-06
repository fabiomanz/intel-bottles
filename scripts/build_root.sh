#!/usr/bin/env bash
#
# Build and bottle one root formula plus everything under it that still needs a bottle.
#
# Dependencies are NOT inherited as --build-bottle installs (Homebrew's install_dependency
# constructs its FormulaInstaller without build_bottle:, so `brew bottle` would refuse them
# with "Formula was not installed with --build-bottle"). So we walk the chain in topological
# order and install each formula we intend to bottle explicitly.
#
# Anything that already has a usable bottle is left alone and simply poured by brew.
#
# Written for bash 3.2 -- macOS runners have no mapfile.

set -euo pipefail

ROOT="${1:?usage: build_root.sh <formula>}"

# This script UNINSTALLS and rebuilds formulae, which is destructive on a real machine.
# It is only ever meant to run on a throwaway CI runner.
if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL_BUILD:-}" != "1" ]; then
  echo "refusing to run: build_root.sh uninstalls and rebuilds formulae and is intended" >&2
  echo "for a disposable CI runner. Set ALLOW_LOCAL_BUILD=1 only if you truly mean it." >&2
  exit 1
fi
: "${BOTTLE_ROOT_URL:?BOTTLE_ROOT_URL must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${BOTTLE_OUT_DIR:-$PWD/bottles}"
mkdir -p "$OUT_DIR"

# Formula names never contain whitespace, so word splitting is safe and keeps this bash-3 clean.
CHAIN="$(brew deps -n --include-build "$ROOT"; echo "$ROOT")"
TODO="$(python3 "$SCRIPT_DIR/filter_unbottled.py" $CHAIN)"

if [ -z "$TODO" ]; then
  echo "==> $ROOT: everything in its chain is already bottled, nothing to do"
  exit 0
fi

echo "==> $ROOT: building $(echo "$TODO" | wc -l | tr -d ' ') formula(e) in dependency order"
echo "$TODO" | sed 's/^/      /'

cd "$OUT_DIR"

for formula in $TODO; do
  echo "::group::build $formula"
  df -h / | tail -1

  # `brew reinstall` has no --build-bottle flag, so anything already present (GitHub's
  # runner image ships a fair few formulae preinstalled) has to be removed first --
  # otherwise `brew install` no-ops and `brew bottle` then refuses the formula.
  if brew list --formula --versions "$formula" >/dev/null 2>&1; then
    echo "    already installed; removing so it can be rebuilt for bottling"
    brew uninstall --ignore-dependencies --force "$formula"
  fi
  # Download sources first, with backoff. Upstream mirrors are flaky -- gmp's primary
  # (ftpmirror.gnu.org) and its mirror (gmplib.org) can both be unreachable for minutes at
  # a time. Fetching separately means a network blip costs seconds instead of discarding a
  # build that may already be hours in, and a successful fetch is cached so the install
  # below does not re-download.
  fetched=0
  fetchlog="$(mktemp)"
  for attempt in 1 2 3 4; do
    if brew fetch --build-bottle --retry "$formula" 2>&1 | tee "$fetchlog"; then
      fetched=1
      break
    fi

    # Some formulae pull resources with tools the runner image does not ship -- netpbm
    # fetches its documentation over svn. Homebrew names exactly what is missing, so
    # install it and retry immediately rather than backing off against a fixed problem.
    missing="$(sed -n 's/.*You must: brew install \([A-Za-z0-9@._+-]*\).*/\1/p' "$fetchlog" | head -1)"
    if [ -n "$missing" ]; then
      echo "    fetch needs $missing, installing it and retrying"
      brew install "$missing" || true
      continue
    fi

    echo "    fetch attempt $attempt failed; backing off $((attempt * 30))s"
    sleep $((attempt * 30))
  done
  if [ "$fetched" != 1 ]; then
    echo "    could not download sources for $formula after 4 attempts" >&2
    exit 1
  fi

  # GitHub's macOS image ships its own Python and friends in /usr/local, so pouring a
  # dependency (python@3.13, say) can fail at the link step with "Target already exists"
  # -- brew then exits non-zero even though the formula we care about built fine. That is
  # what killed pygobject3: it printed its own success line and still failed the job.
  # Force the links and retry once rather than losing a build to a preinstalled file.
  if ! brew install --build-bottle --display-times "$formula"; then
    echo "    install failed; forcing dependency links and retrying once"
    for dep in $(brew deps --include-build "$formula") "$formula"; do
      brew link --overwrite --force "$dep" >/dev/null 2>&1 || true
    done
    brew install --build-bottle --display-times "$formula"
  fi

  brew bottle --json --no-rebuild --root-url "$BOTTLE_ROOT_URL" "$formula"
  echo "::endgroup::"
done

echo "==> $ROOT: produced"
ls -la "$OUT_DIR"
