#!/bin/bash
# Usage: tests/run.sh [filter]  (substring of test function name or file name)
here="$(cd "$(dirname "$0")" && pwd -P)"
filter="${1:-}"
failed=0
total=0
for file in "$here"/test_*.sh; do
  [ -f "$file" ] || continue
  fname="$(basename "$file")"
  for fn in $(grep -oE '^test_[A-Za-z0-9_]+' "$file"); do
    if [ -n "$filter" ]; then
      case "$fname $fn" in *"$filter"*) ;; *) continue ;; esac
    fi
    total=$((total + 1))
    out="$( ( source "$here/helpers.sh"; source "$file"; sandbox_setup; "$fn" ) 2>&1 )"
    rc=$?
    if [ "$rc" = 0 ]; then
      echo "PASS $fn"
    else
      echo "FAIL $fn"
      [ -n "$out" ] && echo "$out" | sed 's/^/    /'
      failed=$((failed + 1))
    fi
  done
done
echo "$((total - failed))/$total passed"
[ "$failed" = 0 ] || exit 1
