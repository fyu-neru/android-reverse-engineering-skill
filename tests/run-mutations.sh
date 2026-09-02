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
if ! "${BASH:-bash}" "$TESTS_DIR/run-tests.sh" >/dev/null 2>&1; then
  echo "ERROR - baseline suite is not green; mutation results would be meaningless."
  echo "        Run 'bash tests/run-tests.sh' and fix it before running mutations."
  exit 1
fi

total=0
survived=0
survivors=""
skipped=0
skipped_names=""

# bash_version_satisfies_lt_4_4 — true when the bash currently running this
# script is older than 4.4. Some defects (the ${arr[@]+"${arr[@]}"} empty-
# array guard) are only observable there: bash 4.4+ changed "${arr[@]}" on
# a zero-element array to expand to nothing under `set -u` instead of
# raising "unbound variable", so a mutation reverting that guard is
# structurally unkillable on bash 4.4+ no matter how the test is written.
# REQUIRES:bash<4.4 in a mutation file opts it out of runs on a newer bash
# rather than let it inflate the survivor count with a result the mutation
# was never able to produce here — the macOS /bin/bash CI step is what
# actually exercises it. BASH_VERSINFO is a plain indexed array (fine on
# bash 3.2 too), so this check itself works everywhere run-mutations.sh does.
bash_version_satisfies_lt_4_4() {
  local major="${BASH_VERSINFO[0]:-0}" minor="${BASH_VERSINFO[1]:-0}"
  if [ "$major" -lt 4 ]; then
    return 0
  fi
  if [ "$major" -eq 4 ] && [ "$minor" -lt 4 ]; then
    return 0
  fi
  return 1
}

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
  name=$(basename "$m" .mutation)

  # A mutation may carry more than one FIND:/REPLACE: pair (in strict
  # alternation) so a single mutation can express a multi-line reversion —
  # e.g. reintroducing an associative array requires both the declaration
  # and the read sites to change together, or the "reversion" describes a
  # defect that never actually existed. Pairs are applied in order, each
  # against the result of the previous one.
  file=""; expect=""; requires=""
  finds=(); replaces=()
  pending_find=""; have_pending_find=false
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FILE:*)     file=${line#FILE:} ;;
      EXPECT:*)   expect=${line#EXPECT:} ;;
      REQUIRES:*) requires=${line#REQUIRES:} ;;
      FIND:*)     pending_find=${line#FIND:}; have_pending_find=true ;;
      REPLACE:*)
        if [ "$have_pending_find" = true ]; then
          finds[${#finds[@]}]="$pending_find"
          replaces[${#replaces[@]}]=${line#REPLACE:}
          have_pending_find=false
        fi
        ;;
    esac
  done < "$m"

  if [ "$requires" = "bash<4.4" ] && ! bash_version_satisfies_lt_4_4; then
    echo "  skip     - $name: REQUIRES bash<4.4, this shell is $BASH_VERSION"
    skipped=$((skipped + 1)); skipped_names="$skipped_names $name"
    continue
  fi

  total=$((total + 1))

  if [ -z "$expect" ]; then
    echo "  ERROR - $name: no EXPECT: field."
    echo "          Every mutation must name a test-file name or assertion-label"
    echo "          substring that must appear among the failures — otherwise a"
    echo "          mutation can be scored 'killed' by an unrelated red assertion"
    echo "          that never actually exercised the defect."
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  if [ "${#finds[@]}" -eq 0 ]; then
    echo "  ERROR - $name: no FIND:/REPLACE: pair found."
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  target="$REPO_ROOT/$file"
  if [ ! -f "$target" ]; then
    echo "  ERROR - $name: target file not found: $file"
    survived=$((survived + 1)); survivors="$survivors $name"
    continue
  fi

  backup="$target.mutation-backup"
  cp "$target" "$backup"
  current_target="$target"
  current_backup="$backup"

  apply_failed=false
  pair_idx=0
  while [ "$pair_idx" -lt "${#finds[@]}" ]; do
    find_line="${finds[$pair_idx]}"
    replace_line="${replaces[$pair_idx]}"

    match_count=$(grep -cFx -- "$find_line" "$target")
    if [ "$match_count" -eq 0 ]; then
      echo "  ERROR - $name: FIND line (pair $((pair_idx + 1))) no longer present in $file."
      echo "          The code moved or changed; re-check whether this"
      echo "          mutation still describes a real defect."
      apply_failed=true
      break
    fi
    if [ "$match_count" -gt 1 ]; then
      echo "  ERROR - $name: FIND line (pair $((pair_idx + 1))) matches $match_count lines in $file, not 1."
      echo "          A non-unique FIND would multi-mutate the file silently;"
      echo "          rewrite the mutation to match a single line uniquely."
      apply_failed=true
      break
    fi

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
    done < "$target"
    mv "$out" "$target"
    current_out=""

    pair_idx=$((pair_idx + 1))
  done

  if [ "$apply_failed" = true ]; then
    survived=$((survived + 1)); survivors="$survivors $name"
    mv -f "$backup" "$target"
    current_target=""
    current_backup=""
    continue
  fi

  mutation_output=$("${BASH:-bash}" "$TESTS_DIR/run-tests.sh" 2>&1)
  mutation_status=$?
  if [ "$mutation_status" -eq 0 ]; then
    echo "  SURVIVED - $name: suite stayed GREEN with the defect reintroduced"
    survived=$((survived + 1)); survivors="$survivors $name"
  else
    # The suite went red — but that alone doesn't prove THIS defect was
    # caught. A mutation can be scored "killed" by an unrelated assertion
    # (a flaky test, a different defect's guard) that fails for reasons
    # having nothing to do with what was just mutated. EXPECT: names a
    # test-file name or assertion-label substring that must appear among
    # the actual failing lines — matching the "  FAIL - <label>" lines
    # this suite's harness emits, or the test-runner's own file-name error
    # line when a whole test file could not even run to completion.
    fail_lines=$(printf '%s\n' "$mutation_output" | grep -E '^  (FAIL - |ERROR - )')
    matched=$(printf '%s\n' "$fail_lines" | grep -F -- "$expect" || true)
    if [ -n "$matched" ]; then
      guard=$(printf '%s\n' "$matched" | sed -E -e 's/^  (FAIL|ERROR) - //' -e '1q')
      echo "  killed   - $name (guard: $guard)"
    else
      echo "  SURVIVED - $name: suite went RED, but not via the expected guard (EXPECT: $expect)"
      echo "             This mutation is being killed by an unrelated failure, not the"
      echo "             guard it claims to exercise — recorded as unguarded. Actual failures:"
      printf '%s\n' "$fail_lines" | sed 's/^/             /'
      survived=$((survived + 1)); survivors="$survivors $name"
    fi
  fi

  mv -f "$backup" "$target"
  current_target=""
  current_backup=""
done

echo
echo "===================================="
echo "Mutations: $total   Survived: $survived   Skipped: $skipped"
if [ "$skipped" -ne 0 ]; then
  echo "Skipped (REQUIRES not met by this shell, $BASH_VERSION):$skipped_names"
fi
if [ "$survived" -ne 0 ]; then
  echo "Surviving mutations (these defects are not actually guarded):$survivors"
  exit 1
fi
echo "Every mutation was killed."

# The baseline check above only covers "the environment was already broken
# before we started." It says nothing about "the environment broke partway
# through" — a mutation left mid-application by a crash, a restore that
# silently failed, a mutation-backup file that leaked into a later run.
# After every mutation has been reintroduced-and-restored, re-run the
# suite once more and require it to still be green; without this, a break
# introduced at mutation 3 of 6 would read as "every mutation killed" for
# every mutation from that point on, since a suite that is already red
# reports every subsequent mutation as trivially "killed".
echo
echo "Re-running the suite once more after all mutations were restored..."
if ! "${BASH:-bash}" "$TESTS_DIR/run-tests.sh" >/dev/null 2>&1; then
  echo "ERROR - suite is not green after restoring every mutation."
  echo "        Something broke mid-run and did not restore cleanly."
  exit 1
fi
echo "Suite is green after full restore."
