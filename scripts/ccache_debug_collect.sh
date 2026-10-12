#!/usr/bin/env bash
#
# Package ccache's per-object debug output for the compilations that MISSED the cache.
#
# With debug on, ccache writes <object>.<timestamp>.ccache-log (why it hit or missed) and
# .ccache-input-{c,d,p,text} (exactly what it hashed) for every compilation. Hits are
# irrelevant and the binary .ccache-input-* files are large, so this keeps only the log
# and the readable input text of misses. Comparing those between two runs shows what
# changes from run to run (ccache manual: "Cache debugging").
#
# usage: ccache_debug_collect.sh <debug-dir> <output.tgz>

set -euo pipefail

DIR="$1"
OUT="$2"

if [ ! -d "$DIR" ]; then
  echo "no ccache debug output in $DIR"
  exit 0
fi

hits=0
misses=0
other=0
while IFS= read -r -d '' log; do
  prefix="${log%.ccache-log}"
  rm -f "$prefix.ccache-input-c" "$prefix.ccache-input-d" "$prefix.ccache-input-p"
  if grep -q 'Result: .*cache_hit' "$log"; then
    rm -f "$log" "$prefix.ccache-input-text"
    hits=$((hits + 1))
  elif grep -q 'Result: .*cache_miss' "$log"; then
    misses=$((misses + 1))
  else
    other=$((other + 1))
  fi
done < <(find "$DIR" -name '*.ccache-log' -print0)

echo "ccache debug: $hits hits dropped, $misses misses kept, $other other results kept"
tar -czf "$OUT" -C "$DIR" .
ls -lh "$OUT"
