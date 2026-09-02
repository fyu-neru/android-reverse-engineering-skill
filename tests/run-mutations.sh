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

# Before mutating anything, confirm the suite is green on its own. If it
# is already red for an unrelated reason (a flaky test, a missing binary,
# a broken environment), every mutation below would appear "killed" while
# having exercised nothing — a false report of full guard coverage. That
# is the exact failure mode this framework exists to prevent, just aimed
# at itself.
if ! bash "$TESTS_DIR/run-tests.sh" >/dev/null 2>&1; then
  echo "ERROR - baseline suite is not green; mutation results would be meaningless."
  echo "        Run 'bash tests/run-tests.sh' and fix it before running mutations."
  exit 1
fi

total=0
survived=0
survivors=""

# State for the in-flight mutation, used by the cleanup trap below so an
# interrupt mid-mutation can never leave a plugin script permanently
# corrupted. cleanup_mutation_state is idempotent and safe to call even
# when no mutation is in flight.
current_target=""
current_backup=""
current_out=""

cleanup_mutation_state() {
  if [ -n "$current_backup" ] && [ -f "$current_backup" ] && [ -n "$current_target" ]; then
    mv -f "$current_backup" "$current_target"
  fi
  if [ -n "$current_out" ] && [ -f "$current_out" ]; then
    rm -f "$current_out"
  fi
  current_target=""
  current_backup=""
  current_out=""
}
trap cleanup_mutation_state EXIT
trap 'cleanup_mutation_state; exit 130' INT
trap 'cleanup_mutation_state; exit 143' TERM

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

  match_count=$(grep -cFx -- "$find_line" "$target")
  if [ "$match_count" -eq 0 ]; then
    echo "  ERROR - $name: FIND line no longer present in $file."
    echo "          The code moved or changed; re-check whether this"
    echo "          mutation still describes a real defect."
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi
  if [ "$match_count" -gt 1 ]; then
    echo "  ERROR - $name: FIND line matches $match_count lines in $file, not 1."
    echo "          A non-unique FIND would multi-mutate the file silently;"
    echo "          rewrite the mutation to match a single line uniquely."
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  backup="$target.mutation-backup"
  cp "$target" "$backup"
  current_target="$target"
  current_backup="$backup"

  # Rewrite the single matching line without sed, so no regex
  # metacharacter in the payload can be misinterpreted.
  out="$target.mutation-tmp"
  current_out="$out"
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$find_line" ]; then
      printf '%s\n' "$replace_line" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$backup"
  mv "$out" "$target"
  current_out=""

  if bash "$TESTS_DIR/run-tests.sh" >/dev/null 2>&1; then
    echo "  SURVIVED - $name: suite stayed GREEN with the defect reintroduced"
    survived=$((survived + 1)); survivors="$survivors $name"
  else
    echo "  killed   - $name"
  fi

  mv -f "$backup" "$target"
  current_target=""
  current_backup=""
done

echo
echo "===================================="
echo "Mutations: $total   Survived: $survived"
if [ "$survived" -ne 0 ]; then
  echo "Surviving mutations (these defects are not actually guarded):$survivors"
  exit 1
fi
echo "Every mutation was killed."
