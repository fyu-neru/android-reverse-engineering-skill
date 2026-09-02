#!/usr/bin/env bash
# Regression tests for check-deps.sh
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/check-deps.sh"

# --- D4: Java version parsing must not depend on GNU grep -oP ---
# Some JDKs print a bare version with no dot (e.g. 'openjdk version "21"'),
# which is exactly the case the -oP fallback was there to handle.
bin=$(new_tmpdir)
make_stub_bin "$bin" java 'echo "openjdk version \"21\"" >&2
echo "OpenJDK Runtime Environment (build 21+35)" >&2
exit 0'

out=$(PATH="$bin:$PATH" bash "$SCRIPT" 2>&1)
assert_contains "$out" "[OK] Java 21 detected" \
  "D4: parses a dotless Java version without grep -oP"

# The common dotted form must keep working.
bin2=$(new_tmpdir)
make_stub_bin "$bin2" java 'echo "openjdk version \"17.0.9\" 2023-10-17" >&2
exit 0'

out2=$(PATH="$bin2:$PATH" bash "$SCRIPT" 2>&1)
assert_contains "$out2" "[OK] Java 17 detected" \
  "D4: parses a dotted Java version"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
