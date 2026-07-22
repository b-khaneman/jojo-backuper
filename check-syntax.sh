#!/usr/bin/env bash
# Quick syntax check for JOJO BACKUPER scripts
set -e
cd "$(dirname "$0")/server-migration-manager"
fail=0
for f in *.sh modules/*.sh; do
  if bash -n "$f"; then
    echo "OK  $f"
  else
    echo "FAIL $f"
    fail=1
  fi
done
exit "$fail"
