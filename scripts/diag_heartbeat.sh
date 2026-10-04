#!/usr/bin/env bash
#
# Push machine health and the tail of the build log to the `diag` branch every few minutes.
#
# When a hosted runner "loses communication", GitHub discards the job's log entirely, so
# a build that dies that way leaves nothing to diagnose. This runs in the background
# during the build and writes diag/<run>-<formula>.txt through the contents API, so the
# last snapshot before the runner died survives it. Enabled per formula through the
# `diag` input of the build workflow; delete the branch when done.
#
# usage: diag_heartbeat.sh <formula> <build-log>

set -u

FORMULA="$1"
BUILD_LOG="$2"
INTERVAL="${DIAG_INTERVAL:-180}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
REPO="${GITHUB_REPOSITORY:?}"
DEST="diag/${GITHUB_RUN_ID:-local}-${FORMULA}.txt"

SAMPLES="$(mktemp)"
REPORT="$(mktemp)"
START=$(date +%s)

if ! gh api "repos/$REPO/git/ref/heads/diag" >/dev/null 2>&1; then
  gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/diag -f sha="${GITHUB_SHA:?}" \
    >/dev/null 2>&1 || true
fi

echo "elapsed  mem_free  swap_used  load1  top_rss_mb top_process" > "$SAMPLES"
while true; do
  elapsed=$(( ($(date +%s) - START) / 60 ))
  free="$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: //p')"
  swap="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([^ ]*\).*/\1/p')"
  load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
  top="$(ps -Ao rss=,ucomm= -m | head -1 | awk '{printf "%d %s", $1/1024, $2}')"
  printf '%5sm  %8s  %9s  %5s  %s\n' "$elapsed" "$free" "$swap" "$load" "$top" >> "$SAMPLES"

  {
    echo "run ${GITHUB_RUN_ID:-local}, $FORMULA, updated $(date -u +%FT%TZ)"
    echo
    cat "$SAMPLES"
    echo
    echo "== top processes by memory (RSS MB)"
    ps -Ao rss=,ucomm= -m | head -8 | awk '{printf "%7d  %s\n", $1/1024, $2}'
    echo
    echo "== vm_stat"
    vm_stat 2>/dev/null | head -12
    echo
    echo "== df /"
    df -h / | tail -1
    echo
    echo "== build log (last 30 lines)"
    tail -30 "$BUILD_LOG" 2>/dev/null | cut -c1-300
  } > "$REPORT"

  sha="$(gh api "repos/$REPO/contents/$DEST?ref=diag" --jq .sha 2>/dev/null || true)"
  gh api -X PUT "repos/$REPO/contents/$DEST" \
    -f message="diag: $FORMULA at ${elapsed}m" -f branch=diag \
    -f content="$(base64 < "$REPORT" | tr -d '\n')" \
    ${sha:+-f sha="$sha"} >/dev/null 2>&1 \
    || echo "diag heartbeat: upload failed at ${elapsed}m" >&2

  sleep "$INTERVAL"
done
