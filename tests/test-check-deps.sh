#!/usr/bin/env bash
# Regression tests for check-deps.sh
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/check-deps.sh"
DECOMPILE_SCRIPT="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh"

# --- D4: Java version parsing must not depend on GNU grep -oP ---
# Some JDKs print a bare version with no dot (e.g. 'openjdk version "21"'),
# which is exactly the case the -oP fallback was there to handle.
bin=$(new_tmpdir)
make_stub_bin "$bin" java 'echo "openjdk version \"21\"" >&2
echo "OpenJDK Runtime Environment (build 21+35)" >&2
exit 0'

out=$(PATH="$bin:$PATH" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out" "[OK] Java 21 detected" \
  "D4: parses a dotless Java version using a portable grep"

# The common dotted form must keep working.
bin2=$(new_tmpdir)
make_stub_bin "$bin2" java 'echo "openjdk version \"17.0.9\" 2023-10-17" >&2
exit 0'

out2=$(PATH="$bin2:$PATH" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out2" "[OK] Java 17 detected" \
  "D4: parses a dotted Java version"

# --- D2 parity: FERNFLOWER_JAR_PATH must win over a CLI on PATH in BOTH
#     check-deps.sh and decompile.sh — a divergence here means the two
#     scripts can disagree about which backend is in effect. ---
home3=$(new_tmpdir)
jarpath="$home3/custom-vineflower.jar"
touch "$jarpath"

bin3=$(new_tmpdir)
make_stub_bin "$bin3" vineflower 'echo "VINEFLOWER_CLI_SHOULD_NOT_RUN"
exit 1'
make_stub_bin "$bin3" java 'echo "JAVA_ARGV: $*"
exit 0'

out3=$(HOME="$home3" PATH="$bin3:$PATH" FERNFLOWER_JAR_PATH="$jarpath" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out3" "[OK] Fernflower/Vineflower JAR found: $jarpath" \
  "D2 parity: check-deps.sh prefers FERNFLOWER_JAR_PATH over a CLI on PATH"

work3=$(new_tmpdir)
touch "$work3/lib.jar"
out4=$(cd "$work3" && HOME="$home3" PATH="$bin3:$PATH" FERNFLOWER_JAR_PATH="$jarpath" \
       "${BASH:-bash}" "$DECOMPILE_SCRIPT" --engine fernflower lib.jar 2>&1)

assert_contains "$out4" "$jarpath" \
  "D2 parity: decompile.sh uses the same FERNFLOWER_JAR_PATH jar as check-deps.sh"
assert_not_contains "$out4" "VINEFLOWER_CLI_SHOULD_NOT_RUN" \
  "D2 parity: decompile.sh does not run the PATH CLI when FERNFLOWER_JAR_PATH is set"

bin5=$(new_tmpdir)
# The padding must reliably overflow the pipe (a few thousand small,
# individually-echoed lines was not: on some platforms/timings the whole
# loop finished, and the OS pipe buffer absorbed it, before a `head -1`
# reader would ever have closed its end — so a `| head -1` regression
# could sit there unnoticed with this assertion still green. Doubling a
# line 16 times builds ~4MB in one write, an order of magnitude past any
# real pipe buffer (typically 16KB-1MB), so a blocked writer racing a
# closed reader is no longer a timing coincidence.
make_stub_bin "$bin5" java 'echo "openjdk version \"17.0.9\" 2023-10-17" >&2
line="padding line to overflow the pipe buffer after the version line"
big="$line"
i=0
while [ "$i" -lt 16 ]; do
  big="$big
$big"
  i=$((i + 1))
done
printf "%s\n" "$big" >&2
exit 0'

out5=$(PATH="$bin5:$PATH" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out5" "[OK] Java 17 detected" \
  "SIGPIPE regression: check-deps.sh must not abort when java prints megabytes after the version line (head -1 | SIGPIPE race)"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
