#!/usr/bin/env bash
# Quick syntax check for JOJO BACKUPER scripts
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
fail=0
while IFS= read -r f; do
  if bash -n "$f"; then
    echo "OK  $f"
  else
    echo "FAIL $f"
    fail=1
  fi
done < <(find "$ROOT" -type f -name '*.sh' ! -name '_debug_check.sh' | sort)
exit "$fail"
