#!/usr/bin/env bash
# The runner must fail loudly when a test file omits its SUMMARY line,
# rather than silently counting it as one failure with no explanation.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

work=$(new_tmpdir)
mkdir -p "$work/tests/lib"
cp "$REPO_ROOT/tests/run-tests.sh" "$work/tests/"
cp "$REPO_ROOT/tests/lib/harness.sh" "$work/tests/lib/"

# A test file that passes its own assertions but forgets the SUMMARY line.
cat > "$work/tests/test-forgot-summary.sh" <<'INNER2'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
echo "  ok   - something"
INNER2

out=$("${BASH:-bash}" "$work/tests/run-tests.sh" 2>&1 || true)

# These check the specific ERROR wording the runner is supposed to emit,
# not just that the filename appears anywhere in the output — the
# pre-existing "Failing files:" summary line already names the file
# regardless of this fix, so a bare filename check would pass identically
# before and after and prove nothing.
assert_contains "$out" "ERROR - test-forgot-summary.sh" \
  "[all] runner names the file that omitted its SUMMARY line"
assert_contains "$out" "produced no 'SUMMARY <run> <failed>' line" \
  "[all] runner explains that the SUMMARY line is what was missing"

# The runner must surface the skipped total in its summary block, not
# only in whatever SKIP: prose a test file printed hundreds of lines
# earlier. Someone comparing a 222-assertion Windows log against a
# 168-assertion CI log has no other way to tell deliberate host gating
# from assertions that quietly stopped being emitted.
#
# Its own work dir, so the missing-SUMMARY fixture above does not also
# run here and muddy the counts.
work2=$(new_tmpdir)
mkdir -p "$work2/tests/lib"
cp "$REPO_ROOT/tests/run-tests.sh" "$work2/tests/"
cp "$REPO_ROOT/tests/lib/harness.sh" "$work2/tests/lib/"

cat > "$work2/tests/test-reports-skips.sh" <<'INNER3'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"
assert_equals "a" "a" "one real assertion, so run and skipped are distinguishable"
skip_group 3 "three assertions deliberately not run here"
print_summary
INNER3

out2=$("${BASH:-bash}" "$work2/tests/run-tests.sh" 2>&1 || true)

assert_contains "$out2" "Skipped: 3" \
  "[all] runner reports the skipped total in its summary block, not only in the SKIP: prose"
assert_contains "$out2" "Tests run: 1" \
  "[all] runner counts run assertions separately from skipped ones"

cleanup_tmpdirs
print_summary
