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

# --- D2 parity: VINEFLOWER_JAR must win over a CLI on PATH in BOTH
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

out3=$(HOME="$home3" PATH="$bin3:$PATH" VINEFLOWER_JAR="$jarpath" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out3" "[OK] Vineflower JAR found: $jarpath" \
  "D2 parity: check-deps.sh prefers VINEFLOWER_JAR over a CLI on PATH"

work3=$(new_tmpdir)
touch "$work3/lib.jar"
out4=$(cd "$work3" && HOME="$home3" PATH="$bin3:$PATH" VINEFLOWER_JAR="$jarpath" \
       "${BASH:-bash}" "$DECOMPILE_SCRIPT" --engine vineflower lib.jar 2>&1)

assert_contains "$out4" "$jarpath" \
  "D2 parity: decompile.sh uses the same VINEFLOWER_JAR jar as check-deps.sh"
assert_not_contains "$out4" "VINEFLOWER_CLI_SHOULD_NOT_RUN" \
  "D2 parity: decompile.sh does not run the PATH CLI when VINEFLOWER_JAR is set"

bin5=$(new_tmpdir)
# Overflowing the pipe buffer by sheer volume was tried first and was
# still a timing race in practice: whether a fast writer finishes (and
# the OS buffer absorbs everything) before a `head -1` reader has even
# been scheduled depends on scheduling luck and the pipe's buffer size,
# neither of which this test controls — confirmed empirically when a
# ~4MB single write still did not reliably trigger the race in CI.
#
# Pausing right after the one line `head -1` actually wants removes the
# race entirely: `head -1` only ever needs that first line, so by the
# time this stub wakes up from the sleep, a `head -1` reader has already
# read it, printed it, and exited — closing its end of the pipe. Every
# padding line written after the pause is therefore written into a pipe
# with no reader left, which raises SIGPIPE deterministically, on any
# buffer size, with no dependency on process-scheduling timing.
make_stub_bin "$bin5" java 'echo "openjdk version \"17.0.9\" 2023-10-17" >&2
sleep 1
i=0
while [ "$i" -lt 5000 ]; do
  echo "padding line $i to overflow the pipe buffer after the version line" >&2
  i=$((i + 1))
done
exit 0'

out5=$(PATH="$bin5:$PATH" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out5" "[OK] Java 17 detected" \
  "SIGPIPE regression: check-deps.sh must not abort when java keeps writing after the version line (head -1 | SIGPIPE race)"

# --- Task 3: check-deps.sh must resolve adb via lib/tools.sh's tool_resolve
#     (env override -> PATH probe -> candidates), not a re-implemented,
#     PATH-only `command -v adb` check. A hardcoded PATH-only check cannot
#     see ADB_BIN at all, so this is only satisfiable by actually consuming
#     the reader — exactly the regression psv-check-deps-reader-link.mutation
#     reintroduces. ---
emptybin6=$(new_tmpdir)
home6=$(new_tmpdir)
adb_target="$home6/custom-adb"
touch "$adb_target"

out6=$(HOME="$home6" PATH="$emptybin6:$PATH" ADB_BIN="$adb_target" "${BASH:-bash}" "$SCRIPT" 2>&1)
assert_contains "$out6" "[OK] adb detected (optional)" \
  "[all] Task 3: check-deps.sh resolves adb via the ADB_BIN env override with no adb on PATH (proves it consumes tools.sh's tool_resolve rather than a hardcoded PATH-only check)"

# --- Task 2 (2.1.0, D7): python3 must be declared as a dependency, with
# stub detection that actually runs the resolved interpreter rather than
# trusting a name on PATH. This development machine's own `python3` is a
# Windows Store app-execution-alias stub: it resolves via PATH/command -v
# but exits 49 with no version output when actually run — verified above
# by hand against the real environment. A detection that stopped at "is
# python3 on PATH" would report this machine's own stub as [OK].
#
# All three cases filter this machine's real PATH down to directories that
# do NOT contain a python3/python3.exe/python3.bat/python3.cmd (the same
# technique test-decompile.sh's D10/D14 use for jadx), so resolution is
# genuinely forced through each stub rather than accidentally finding this
# machine's own real python3 stub.
path_no_py3=""
_pnp_oldifs="$IFS"
IFS=':'
for _pnp_dir in $PATH; do
  IFS="$_pnp_oldifs"
  if [ -n "$_pnp_dir" ] && [ ! -f "$_pnp_dir/python3" ] && [ ! -f "$_pnp_dir/python3.exe" ] && [ ! -f "$_pnp_dir/python3.bat" ] && [ ! -f "$_pnp_dir/python3.cmd" ]; then
    path_no_py3="${path_no_py3:+$path_no_py3:}$_pnp_dir"
  fi
  IFS=':'
done
IFS="$_pnp_oldifs"

# Case 1: no python3 anywhere (no PATH match, no PYTHON3_BIN, no
# candidates — tools.psv's python3 row has none) -> [MISSING].
out_py3_case1=$(PATH="$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case1=$(printf '%s\n' "$out_py3_case1" | grep -E '^\[(OK|MISSING)\].*python3' || true)
assert_contains "$py3_line_case1" "[MISSING] python3" \
  "[all] Task2 case 1: check-deps.sh reports [MISSING] python3 when nothing named python3 resolves at all"

# Case 2 (the core of this task): a python3 ON PATH that is a stub — exits
# non-zero and prints no version output, exactly like this machine's real
# Windows Store stub reproduced above. Must NOT be reported [OK]; a
# detection reduced to `command -v python3 && echo OK` would report this
# as installed.
bin_py3_stub=$(new_tmpdir)
make_stub_bin "$bin_py3_stub" python3 'exit 49'

out_py3_case2=$(PATH="$bin_py3_stub:$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case2=$(printf '%s\n' "$out_py3_case2" | grep -E '^\[(OK|MISSING)\].*python3' || true)
assert_not_contains "$py3_line_case2" "[OK]" \
  "[all] Task2 case 2: a python3 stub that exits non-zero with no version output must NOT be reported [OK]"
assert_contains "$py3_line_case2" "[MISSING]" \
  "[all] Task2 case 2: the python3 stub is reported [MISSING] (an explicit stub message), not silently accepted"

# Case 3: a genuinely working python3 -> [OK] with its version. Simulates
# the two distinct -c invocations check-deps.sh actually makes (the
# sys.version_info[0] check, then the platform.python_version() display
# call) by branching on which code string it was handed.
bin_py3_ok=$(new_tmpdir)
make_stub_bin "$bin_py3_ok" python3 'code="$2"
case "$code" in
  *version_info*) echo "3" ;;
  *python_version*) echo "3.11.4" ;;
  *) echo "3" ;;
esac
exit 0'

out_py3_case3=$(PATH="$bin_py3_ok:$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case3=$(printf '%s\n' "$out_py3_case3" | grep -E '^\[(OK|MISSING)\].*python3' || true)
assert_contains "$py3_line_case3" "[OK] python3 3.11.4" \
  "[all] Task2 case 3: a genuinely working python3 interpreter is reported [OK] with its version"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
