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

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
