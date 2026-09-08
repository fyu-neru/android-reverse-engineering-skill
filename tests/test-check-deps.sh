#!/usr/bin/env bash
# Regression tests for check-deps.sh
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR_PS="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"
SCRIPT="$SCRIPTS_DIR_PS/check-deps.sh"
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
# Every case below needs the interpreter to be unresolvable except
# through the stub that case provides. That means scrubbing EVERY name
# the python3 row probes for, not just the literal "python3":
# widening the probe list to python3,python,py made a PATH that merely
# lacks python3 stop being an isolated fixture. These cases went green
# to red the moment a real Python was installed on the development
# machine, because resolution simply walked on to the real `python`.
#
# The names come from the row itself rather than a hardcoded list, so
# the fixture cannot drift away from what the row actually probes — it
# already did that once.
#
# path_without_command mirrors a PATH directory holding the name into a
# temp directory with that name omitted, rather than dropping the
# directory outright: on Linux python3 shares /usr/bin with grep, sed and
# dirname, and dropping it stops check-deps.sh producing output at all.
# See harness.sh.
PLUGIN_ROOT_CD="$REPO_ROOT/plugins/android-reverse-engineering"
TOOLS_SH_CD="$PLUGIN_ROOT_CD/skills/android-reverse-engineering/scripts/lib/tools.sh"
py3_probe_names=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_CD" TOOLS_SH_PATH="$TOOLS_SH_CD" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_field python3 probe')

# This file runs under `set -uo pipefail` with no -e, so a failed
# subshell above would leave py3_probe_names empty — and then the scrub
# loop, the leak loop and the leak assertion would all iterate nothing
# and pass while the PATH stayed completely unscrubbed. Prove the read
# worked before relying on it.
assert_contains "$py3_probe_names" "python3" \
  "[all] Task2 precondition: the probe list was actually read from tools.psv (an empty one makes every scrub below a silent no-op, and the leak check below vacuous)"

sc_probe_oldpath="$PATH"
sc_probe_oldifs="$IFS"
sc_scrub_failed=""
IFS=','
for sc_probe_name in $py3_probe_names; do
  IFS="$sc_probe_oldifs"
  if [ -n "$sc_probe_name" ] && [ "$sc_probe_name" != "-" ]; then
    # path_without_command fails loudly rather than hand back a PATH that
    # silently lost a directory's tools; discarding that status here
    # would put the lie straight back.
    if sc_scrubbed=$(path_without_command "$sc_probe_name"); then
      PATH="$sc_scrubbed"
    else
      sc_scrub_failed="$sc_scrub_failed $sc_probe_name"
    fi
  fi
  IFS=','
done
IFS="$sc_probe_oldifs"
path_no_py3="$PATH"
PATH="$sc_probe_oldpath"

assert_equals "$sc_scrub_failed" "" \
  "[all] Task2 precondition: path_without_command succeeded for every probed name (a failure there means the fixture PATH is missing tools, not just Python)"

# A fixture that still resolves one of those names would make every
# [MISSING] assertion below meaningless, so prove it does not.
sc_probe_leak=""
sc_probe_oldifs="$IFS"
IFS=','
for sc_probe_name in $py3_probe_names; do
  IFS="$sc_probe_oldifs"
  if [ -n "$sc_probe_name" ] && [ "$sc_probe_name" != "-" ]; then
    if PATH="$path_no_py3" command -v "$sc_probe_name" >/dev/null 2>&1; then
      sc_probe_leak="$sc_probe_leak $sc_probe_name"
    fi
  fi
  IFS=','
done
IFS="$sc_probe_oldifs"
assert_equals "$sc_probe_leak" "" \
  "[all] Task2 precondition: the scrubbed PATH resolves none of the names tools.psv's python3 row probes for (otherwise every [MISSING] case below is testing this machine's own Python)"

# Case 1: no python3 anywhere (no PATH match, no PYTHON3_BIN, no
# candidates — tools.psv's python3 row has none) -> [MISSING].
out_py3_case1=$(PATH="$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case1=$(printf '%s\n' "$out_py3_case1" | grep -E '^\[(OK|MISSING)\].*python3' || true)
if [ -n "$py3_line_case1" ]; then py3_seen_case1=present; else py3_seen_case1=absent; fi
assert_equals "$py3_seen_case1" "present"   "[all] Task2 case 1 precondition: check-deps.sh emitted a python3 status line at all (every assertion below is vacuous against an empty one)"
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
if [ -n "$py3_line_case2" ]; then py3_seen_case2=present; else py3_seen_case2=absent; fi
assert_equals "$py3_seen_case2" "present"   "[all] Task2 case 2 precondition: check-deps.sh emitted a python3 status line at all (every assertion below is vacuous against an empty one)"
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
if [ -n "$py3_line_case3" ]; then py3_seen_case3=present; else py3_seen_case3=absent; fi
assert_equals "$py3_seen_case3" "present"   "[all] Task2 case 3 precondition: check-deps.sh emitted a python3 status line at all (every assertion below is vacuous against an empty one)"
assert_contains "$py3_line_case3" "[OK] python3 3.11.4" \
  "[all] Task2 case 3: a genuinely working python3 interpreter is reported [OK] with its version"

# Case 4 — the configuration this row was actually written for, and the
# one it got wrong. On Windows `python3` resolves to the Microsoft Store
# app-execution-alias stub, and the working interpreter is named
# `python`: python.org's Windows installer creates python.exe and
# pythonw.exe and never a python3.exe, so the name python3 can only ever
# find the stub there. Verified on the machine this was written on after
# installing Python 3.12.10 — `python3` exits 49, `python` prints 3.
#
# Resolving the first name that exists and stopping means reporting
# [MISSING] to someone with a perfectly good Python 3.12 installed.
bin_py3_stub_only=$(new_tmpdir)
make_stub_bin "$bin_py3_stub_only" python3 'exit 49'
bin_py_real=$(new_tmpdir)
make_stub_bin "$bin_py_real" python 'code="$2"
case "$code" in
  *version_info*) echo "3" ;;
  *python_version*) echo "3.12.10" ;;
  *) echo "3" ;;
esac
exit 0'

out_py3_case4=$(PATH="$bin_py3_stub_only:$bin_py_real:$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case4=$(printf '%s\n' "$out_py3_case4" | grep -E '^\[(OK|MISSING)\].*python3' || true)
if [ -n "$py3_line_case4" ]; then py3_seen_case4=present; else py3_seen_case4=absent; fi
assert_equals "$py3_seen_case4" "present" \
  "[all] Task2 case 4 precondition: check-deps.sh emitted a python3 status line at all (every assertion below is vacuous against an empty one)"
assert_contains "$py3_line_case4" "[OK] python3 3.12.10" \
  "[all] Task2 case 4: a stub named python3 alongside a working interpreter named python is reported [OK] via the working one"

# Case 5 — a stub and nothing else. The diagnostic must still name the
# path it found, because "not found" is a misleading thing to tell
# someone who can see python3 on their own PATH.
out_py3_case5=$(PATH="$bin_py3_stub_only:$path_no_py3" env -u PYTHON3_BIN "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case5=$(printf '%s\n' "$out_py3_case5" | grep -E '^\[(OK|MISSING)\].*python3' || true)
if [ -n "$py3_line_case5" ]; then py3_seen_case5=present; else py3_seen_case5=absent; fi
assert_equals "$py3_seen_case5" "present" \
  "[all] Task2 case 5 precondition: check-deps.sh emitted a python3 status line at all"
assert_contains "$py3_line_case5" "$bin_py3_stub_only/python3" \
  "[all] Task2 case 5: with only a stub present, the [MISSING] line names the path it found rather than claiming python3 is not there"

# Case 6 — PYTHON3_BIN is honoured exactly as given, deliberately.
# An override states intent; resolution quietly substituting a different
# interpreter for the one the caller named would be worse than reporting
# on theirs. That makes check-deps.sh's own interpreter check the ONLY
# thing between an override pointing at a stub and an [OK] line, now
# that the probe path can no longer produce that situation itself.
#
# Before this case existed, check-deps-python3-stub-not-executed.mutation
# guarded nothing: with verification moved into the resolver, neutering
# check-deps' check left every probe-path assertion still passing, and
# the mutation reported as a survivor on CI.
bin_py3_override=$(new_tmpdir)
make_stub_bin "$bin_py3_override" python3 'exit 49'

out_py3_case6=$(PATH="$path_no_py3" PYTHON3_BIN="$bin_py3_override/python3" \
  "${BASH:-bash}" "$SCRIPT" 2>&1)
py3_line_case6=$(printf '%s\n' "$out_py3_case6" | grep -E '^\[(OK|MISSING)\].*python3' || true)
if [ -n "$py3_line_case6" ]; then py3_seen_case6=present; else py3_seen_case6=absent; fi
assert_equals "$py3_seen_case6" "present" \
  "[all] Task2 case 6 precondition: check-deps.sh emitted a python3 status line at all (the not-contains below is vacuous against an empty one)"
assert_not_contains "$py3_line_case6" "[OK]" \
  "[all] Task2 case 6: a PYTHON3_BIN override pointing at a stub is not reported [OK] — the override is honoured unverified, so check-deps' own interpreter check is the only guard left on that path"

# =====================================================================
# check-deps.ps1's python3 branch, run for real.
#
# Until this existed, those lines were syntax-checked and nothing more,
# and that is exactly how two defects shipped green: Get-Command returns
# EVERY PATH match, so `$cmd.Source` was an Object[] whenever a probed
# name existed in two directories — which is the normal state of
# `python` on a Windows box with a real install alongside the Store
# alias. Binding that to a [string] parameter is a terminating error
# under $ErrorActionPreference = 'Stop', and check-deps.ps1 died at
# `Resolve-Tool -Id 'python3'` with no python3 line, no
# INSTALL_OPTIONAL: lines, no summary and exit 1.
#
# This is the [win] counterpart of case 5 above: with only a stub
# present, the [MISSING] line has to name the path it found.
# =====================================================================
PWSH_BIN=""
if command -v pwsh >/dev/null 2>&1; then
  PWSH_BIN="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  PWSH_BIN="powershell"
fi

# Driven through a fixture tools.psv, not the real one.
#
# check-deps.ps1 refreshes $env:PATH from the User environment variable
# on startup so tools installed in the same session are picked up, which
# means a caller cannot narrow the PATH it searches. But it reads its
# tool list through Get-ToolsPsvPath, which honours CLAUDE_PLUGIN_ROOT
# (Tools.ps1:17-22) — so a fixture psv holding one python3 row makes the
# outcome deterministic AND stops the run touching this machine's real
# tools at all.
#
# That second part is not tidiness. Against the real psv this block
# resolved jadx to an extension-less file and ran `& <path> --version`,
# which makes Windows raise its "how do you want to open this file"
# picker: measured, one OpenWith process left behind per invocation, and
# run-mutations.sh runs the suite ~69 times.
if ! is_windows_host; then
  skip_group 3 "not running on a Windows host; skipping the [win] check-deps.ps1 checks (3 assertions need a real PowerShell host)."
elif [ -z "$PWSH_BIN" ]; then
  skip_group 3 "on a Windows host but neither pwsh nor powershell found on PATH; skipping the same 3 [win] check-deps.ps1 assertions."
else
  cdps_root=$(new_tmpdir)
  cdps_lib="$cdps_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$cdps_lib"
  cat > "$cdps_lib/tools.psv" <<'PSV'
id|required|platform|kind|probe|verify|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
python3|optional|all|path|cdps-nosuch-zzz3,cdps-nosuch-zzz|python3|PYTHON3_BIN|-|-|-|-|-|fixture row
PSV

  native_check_deps_ps1=$(to_native_path "$SCRIPTS_DIR_PS/check-deps.ps1")
  native_cdps_root=$(to_native_path "$cdps_root")
  cdps_script_dir=$(new_tmpdir)
  cdps_script="$cdps_script_dir/cdps-run.ps1"
  cat > "$cdps_script" <<'EOF'
$ErrorActionPreference = 'Continue'
Remove-Item Env:\PYTHON3_BIN -ErrorAction SilentlyContinue
& $env:CHECK_DEPS_PS1 2>&1 | ForEach-Object { Write-Output $_ }
EOF

  cdps_out=$(CHECK_DEPS_PS1="$native_check_deps_ps1" CLAUDE_PLUGIN_ROOT="$native_cdps_root" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$cdps_script" 2>&1 | tr -d '\r')

  cdps_py3_line=$(printf '%s\n' "$cdps_out" | grep -E '^\[(OK|MISSING)\].*python3' || true)
  if [ -n "$cdps_py3_line" ]; then cdps_seen=present; else cdps_seen=absent; fi
  assert_equals "$cdps_seen" "present" \
    "[win] check-deps.ps1 emits a python3 status line at all (an unwrapped Get-Command made \$cmd.Source an Object[] wherever a probed name has two PATH matches, and binding that to a [string] parameter aborted the script before this line)"
  assert_not_contains "$cdps_py3_line" "[OK]" \
    "[win] check-deps.ps1: with no probe name resolving to anything, python3 is not reported [OK]"
  cdps_summary=$(printf '%s\n' "$cdps_out" | grep -E "dependenc(y|ies)" || true)
  if [ -n "$cdps_summary" ]; then cdps_finished=yes; else cdps_finished=no; fi
  assert_equals "$cdps_finished" "yes" \
    "[win] check-deps.ps1 runs through to its dependency summary rather than dying partway (the abort left no summary and no INSTALL_ lines at all)"
fi

cleanup_tmpdirs
print_summary
