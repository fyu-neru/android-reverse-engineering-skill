#!/usr/bin/env bash
# run-tests.sh — run every tests/test-*.sh and report a combined result.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
total_run=0
total_failed=0
failed_files=""

for t in "$TESTS_DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  echo "== $(basename "$t")"
  # Each test file prints "SUMMARY <run> <failed>" as its final line.
  output=$(bash "$t" 2>&1)
  echo "$output" | grep -v '^SUMMARY '
  summary=$(echo "$output" | grep '^SUMMARY ' | tail -1)
  if [ -z "$summary" ]; then
    echo "  ERROR - $(basename "$t") produced no 'SUMMARY <run> <failed>' line."
    echo "          Every test file must print that as its final stdout line;"
    echo "          without it the runner cannot tell passes from crashes."
    run=0
    failed=1
  else
    run=$(echo "$summary" | awk '{print $2}')
    failed=$(echo "$summary" | awk '{print $3}')
    [ -n "$run" ] || run=0
    [ -n "$failed" ] || failed=1
  fi
  total_run=$((total_run + run))
  total_failed=$((total_failed + failed))
  if [ "$failed" -ne 0 ]; then
    failed_files="$failed_files $(basename "$t")"
  fi
done

echo
echo "===================================="
echo "Tests run: $total_run   Failed: $total_failed"
if [ "$total_failed" -ne 0 ]; then
  echo "Failing files:$failed_files"
  exit 1
fi
echo "All tests passed."
