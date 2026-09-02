#!/usr/bin/env bash
# run-mutations.sh — prove each regression test actually catches its defect.
#
# For every tests/mutations/*.mutation: reintroduce the defect, run the
# suite, assert the suite goes RED, then restore. A mutation that leaves
# the suite green means the test guarding that defect verifies nothing.
#
# This exists because four separate tests in the 1.5.1 release passed
# while checking nothing, and each was caught only by manually reverting
# the fix and re-running. This automates that check.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

total=0
survived=0
survivors=""

for m in "$TESTS_DIR"/mutations/*.mutation; do
  [ -f "$m" ] || continue
  total=$((total + 1))
  name=$(basename "$m" .mutation)

  file=""; find_line=""; replace_line=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FILE:*)    file=${line#FILE:} ;;
      FIND:*)    find_line=${line#FIND:} ;;
      REPLACE:*) replace_line=${line#REPLACE:} ;;
    esac
  done < "$m"

  target="$REPO_ROOT/$file"
  if [ ! -f "$target" ]; then
    echo "  ERROR - $name: target file not found: $file"
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  if ! grep -qF -- "$find_line" "$target"; then
    echo "  ERROR - $name: FIND line no longer present in $file."
    echo "          The code moved or changed; re-check whether this"
    echo "          mutation still describes a real defect."
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  backup="$target.mutation-backup"
  cp "$target" "$backup"

  # Rewrite the single matching line without sed, so no regex
  # metacharacter in the payload can be misinterpreted.
  out="$target.mutation-tmp"
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$find_line" ]; then
      printf '%s\n' "$replace_line" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$backup"
  mv "$out" "$target"

  if bash "$TESTS_DIR/run-tests.sh" >/dev/null 2>&1; then
    echo "  SURVIVED - $name: suite stayed GREEN with the defect reintroduced"
    survived=$((survived + 1)); survivors="$survivors $name"
  else
    echo "  killed   - $name"
  fi

  mv "$backup" "$target"
done

echo
echo "===================================="
echo "Mutations: $total   Survived: $survived"
if [ "$survived" -ne 0 ]; then
  echo "Surviving mutations (these defects are not actually guarded):$survivors"
  exit 1
fi
echo "Every mutation was killed."
