#!/usr/bin/env bash
# tests/windows/run.sh - run the Windows adaptation suite.
#
# Every file here runs on BOTH hosts:
#   - Windows (Git Bash): the MSYS branches execute for real.
#   - Linux/macOS: the same cases run behind a fake `uname` that reports
#     MINGW64_NT-10.0-26100, so the Windows branches stay covered in CI
#     without a Windows runner.
# The suite never touches a live herdr server, a real HOME, or the network.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$HERE"/*.test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t")"
  if bash "$t"; then
    :
  else
    echo "FAILED: $t" >&2
    rc=1
  fi
done
if [ "$rc" -eq 0 ]; then
  echo "windows suite: all tests passed"
fi
exit "$rc"
