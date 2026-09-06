#!/usr/bin/env bash
# Regression tests for decompile.sh
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"
SCRIPT="$SCRIPT_DIR/decompile.sh"

# --- D4: print_structure must list packages without GNU find -printf ---
# Drive the real script with a stub jadx that materialises a package tree.
work=$(new_tmpdir)
bin=$(new_tmpdir)
make_stub_bin "$bin" jadx 'out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then out="$a"; fi
  prev="$a"
done
mkdir -p "$out/sources/com/example/network"
mkdir -p "$out/sources/com/example/model"
echo "class A {}" > "$out/sources/com/example/network/A.java"
exit 0'

touch "$work/app.apk"
out=$(cd "$work" && PATH="$bin:$PATH" "${BASH:-bash}" "$SCRIPT" app.apk 2>&1)

assert_contains "$out" "com/example/network" \
  "D4: print_structure lists nested packages using a portable find"
assert_not_contains "$out" "Top-level packages (jadx):
(none)" \
  "D4: print_structure does not silently report (none)"

# --- D2: decompile must find the Vineflower that install-dep just placed ---
# install-dep.sh installs to ~/.local/share/vineflower/vineflower.jar.
home=$(new_tmpdir)
mkdir -p "$home/.local/share/vineflower"
touch "$home/.local/share/vineflower/vineflower.jar"

bin=$(new_tmpdir)
# Stub java so the run does not need a real JVM; echo argv so we can assert.
make_stub_bin "$bin" java 'echo "JAVA_ARGV: $*"
exit 0'

work=$(new_tmpdir)
touch "$work/lib.jar"

out=$(cd "$work" && HOME="$home" PATH="$bin:$PATH" \
      env -u FERNFLOWER_JAR_PATH -u VINEFLOWER_JAR "${BASH:-bash}" "$SCRIPT" --engine vineflower lib.jar 2>&1)

assert_contains "$out" "$home/.local/share/vineflower/vineflower.jar" \
  "D2: decompile finds the jar installed by install-dep.sh"

# --- D2: a Vineflower CLI on PATH must be honoured (the brew install case) ---
home2=$(new_tmpdir)
bin2=$(new_tmpdir)
make_stub_bin "$bin2" vineflower 'echo "VINEFLOWER_CLI_ARGV: $*"
exit 0'
make_stub_bin "$bin2" java 'echo "JAVA_SHOULD_NOT_RUN"
exit 1'

work2=$(new_tmpdir)
touch "$work2/lib.jar"

out2=$(cd "$work2" && HOME="$home2" PATH="$bin2:$PATH" \
       env -u FERNFLOWER_JAR_PATH -u VINEFLOWER_JAR "${BASH:-bash}" "$SCRIPT" --engine vineflower lib.jar 2>&1)

assert_contains "$out2" "VINEFLOWER_CLI_ARGV" \
  "D2: decompile uses a vineflower CLI found on PATH"
assert_not_contains "$out2" "JAVA_SHOULD_NOT_RUN" \
  "D2: decompile does not fall back to java -jar when a CLI is present"

# D3 ("the XAPK temp dir must be removed even when decompilation fails") is
# gone, not merely moved: 2.0.0 deletes the hand-rolled XAPK extraction
# entirely (mktemp -d, its guarding trap, the manifest/OBB handling, and
# the per-APK loop) in favor of handing .xapk straight to jadx, which
# understands the format natively. There is no longer a temp dir for a
# trap to clean up, so the code this test guarded no longer exists. It is
# deleted here — along with tests/mutations/d3-no-trap.mutation, which
# targeted the same trap — rather than left in place where it could only
# ever pass trivially.

# --- D5: the vineflower engine must refuse non-JVM-bytecode input now
# that dex2jar has been removed, rather than silently doing nothing
# useful or crashing deeper in the pipeline. ---
work5=$(new_tmpdir)
touch "$work5/app.apk"

out5=$(cd "$work5" && "${BASH:-bash}" "$SCRIPT" --engine vineflower app.apk 2>&1)
status5=$?

assert_equals "$status5" "1" \
  "[all] D5: --engine vineflower on a .apk exits non-zero (dex2jar removed, no DEX support)"
assert_contains "$out5" "only decompiles .jar, .aar, and .class" \
  "[all] D5: --engine vineflower refusal names the accepted extensions"
assert_contains "$out5" "dex2jar conversion has been removed" \
  "[all] D5: --engine vineflower refusal explains WHY .apk is rejected (not just that it is)"

# --- D6: print_structure must not let an obfuscated APK's dozens of
# single-letter package directories crowd out a real package name like
# com/ once the 20-entry cap is applied. ---
work6=$(new_tmpdir)
bin6=$(new_tmpdir)
# A single-letter top-level package ("a") that alone branches into more
# than 20 nested directories sorts entirely before "com" under a plain
# lexicographic sort (single letters a-z would not: "com" interleaves
# between "c" and "d" regardless of how many other letters exist, so a
# flat a-z spread never actually reproduces the crowding-out this test
# guards against — a single wide single-letter branch does).
make_stub_bin "$bin6" jadx 'out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then out="$a"; fi
  prev="$a"
done
mkdir -p "$out/sources/com/example/network"
i=1
while [ "$i" -le 25 ]; do
  mkdir -p "$out/sources/a/sub$i"
  i=$((i + 1))
done
echo "class A {}" > "$out/sources/com/example/network/A.java"
exit 0'

touch "$work6/obfuscated.apk"
out6=$(cd "$work6" && PATH="$bin6:$PATH" "${BASH:-bash}" "$SCRIPT" obfuscated.apk 2>&1)

assert_contains "$out6" "com/example" \
  "[all] D6: print_structure surfaces com/ among dozens of single-letter obfuscated package dirs"
assert_contains "$out6" "more (showing" \
  "[all] D6: print_structure states the true total when the cap truncates the listing"

# --- D8: .xapk is handed directly to jadx; no hand-rolled extraction step
# remains (2.0.0 deletes it — jadx supports .xapk/.apkm/.apks/.aab/.dex/.zip
# natively, per the design doc's audit of jadx's own usage string). ---
work8=$(new_tmpdir)
bin8=$(new_tmpdir)
make_stub_bin "$bin8" jadx 'echo "JADX_ARGV: $*"
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then out="$a"; fi
  prev="$a"
done
mkdir -p "$out/sources"
exit 0'

touch "$work8/bundle.xapk"
out8=$(cd "$work8" && PATH="$bin8:$PATH" "${BASH:-bash}" "$SCRIPT" bundle.xapk 2>&1)

assert_contains "$out8" "JADX_ARGV" \
  "[all] D8: a .xapk file is handed straight to jadx"
# Asserting "bundle.xapk" against the whole $out8 would pass even if jadx
# had been handed an extracted inner APK instead: the script's own
# "=== Decompiling bundle.xapk ..." header echoes that filename
# regardless of what jadx actually received. Extract just the stub's
# JADX_ARGV line and check the filename there, which is the only line
# that reflects what was actually passed as an argument to jadx.
jadx_argv_line8=$(printf '%s\n' "$out8" | grep '^JADX_ARGV:' || true)
assert_contains "$jadx_argv_line8" "bundle.xapk" \
  "[all] D8: jadx receives the original .xapk path, not an extracted inner APK"
assert_not_contains "$out8" "Extracting XAPK archive" \
  "[all] D8: no hand-rolled XAPK extraction step remains"

# --- D9: the widened extension whitelist accepts the formats jadx added
# native support for (.apkm, .dex) instead of rejecting them up front. ---
work9=$(new_tmpdir)
touch "$work9/app.apkm"
out9=$(cd "$work9" && PATH="$bin8:$PATH" "${BASH:-bash}" "$SCRIPT" app.apkm 2>&1)
assert_not_contains "$out9" "Unsupported file type" \
  "[all] D9: .apkm is accepted by the widened extension whitelist"

work9b=$(new_tmpdir)
touch "$work9b/classes.dex"
out9b=$(cd "$work9b" && PATH="$bin8:$PATH" "${BASH:-bash}" "$SCRIPT" classes.dex 2>&1)
assert_not_contains "$out9b" "Unsupported file type" \
  "[all] D9: .dex is accepted by the widened extension whitelist"

# --- D10 (review round 1, I4): decompile must find jadx via a tools.psv
# candidate path when nothing is on PATH — the same install-then-can't-
# find-it divergence check-deps.sh already avoids for jadx (and that
# check-deps/decompile could reproduce for vineflower, per D2 above,
# before this task started). run_jadx used to do a bare `command -v
# jadx`, which is exactly what misses a jadx that install-dep.sh just
# placed at one of tools.psv's candidate paths, e.g.
# {HOME}/.local/share/jadx/bin/jadx.
home10=$(new_tmpdir)
mkdir -p "$home10/.local/share/jadx/bin"
make_stub_bin "$home10/.local/share/jadx/bin" jadx 'echo "JADX_CANDIDATE_ARGV: $*"
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then out="$a"; fi
  prev="$a"
done
mkdir -p "$out/sources"
exit 0'

# Build a PATH with every real-jadx-containing directory stripped out, so
# resolution is forced past the PATH probe and down to the tools.psv
# candidate above — while keeping every OTHER directory, since decompile.sh
# itself needs find/mkdir/basename/realpath/etc. on PATH to run at all. A
# plain empty PATH would break the script itself, not just hide jadx (this
# machine has a real jadx installed, unlike a typical fresh CI box).
path10=""
_p10_oldifs="$IFS"
IFS=':'
for _p10_dir in $PATH; do
  IFS="$_p10_oldifs"
  if [ -n "$_p10_dir" ] && [ ! -f "$_p10_dir/jadx" ] && [ ! -f "$_p10_dir/jadx.bat" ] && [ ! -f "$_p10_dir/jadx.cmd" ]; then
    path10="${path10:+$path10:}$_p10_dir"
  fi
  IFS=':'
done
IFS="$_p10_oldifs"

work10=$(new_tmpdir)
touch "$work10/app.apk"

out10=$(cd "$work10" && HOME="$home10" PATH="$path10" \
        env -u JADX_BIN "${BASH:-bash}" "$SCRIPT" app.apk 2>&1)

assert_contains "$out10" "JADX_CANDIDATE_ARGV" \
  "[all] D10: decompile finds jadx via a tools.psv candidate path when nothing is on PATH"

# --- D12 (review round 1, minor): --engine both must also refuse a .apk
# (via its vineflower pass), not just --engine vineflower alone. jadx's
# pass runs and succeeds first; the vineflower pass then hits the same
# extension guard as D5 and the whole run fails. ---
work12=$(new_tmpdir)
bin12=$(new_tmpdir)
make_stub_bin "$bin12" jadx 'out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then out="$a"; fi
  prev="$a"
done
mkdir -p "$out/sources"
echo "class A {}" > "$out/sources/A.java"
exit 0'

touch "$work12/app.apk"
out12=$(cd "$work12" && PATH="$bin12:$PATH" "${BASH:-bash}" "$SCRIPT" --engine both app.apk 2>&1)
status12=$?

assert_equals "$status12" "1" \
  "[all] D12: --engine both on a .apk exits non-zero (vineflower pass refuses)"
assert_contains "$out12" "only decompiles .jar, .aar, and .class" \
  "[all] D12: --engine both's vineflower pass names the accepted extensions when it refuses"

# --- D15 (Task 8): --engine fernflower is a renamed value, not one
# decompile.sh still accepts. It must print a migration hint the user can
# act on and refuse to run — this is not a compatibility shim, it never
# falls through to running the vineflower engine under the old name. ---
work15=$(new_tmpdir)
touch "$work15/lib.jar"
out15=$(cd "$work15" && env -u FERNFLOWER_JAR_PATH -u VINEFLOWER_JAR \
        "${BASH:-bash}" "$SCRIPT" --engine fernflower lib.jar 2>&1)
status15=$?

assert_equals "$status15" "1" \
  "[all] D15: --engine fernflower exits non-zero (renamed to --engine vineflower in 2.0.0)"
assert_contains "$out15" "--engine fernflower 已於 2.0.0 更名為 --engine vineflower" \
  "[all] D15: --engine fernflower prints the exact migration hint"

# --- D16 (Task 8): a stale FERNFLOWER_JAR_PATH left in the environment
# must be caught with the same migration hint, not silently ignored —
# silently ignoring it would leave decompile.sh falling back to whatever
# vineflower.jar the PATH/candidate probe happens to find instead of the
# jar the user meant, with no indication anything was skipped. Deliberately
# uses the default (jadx) engine to prove the check fires regardless of
# --engine, not just when vineflower is actually selected. ---
work16=$(new_tmpdir)
touch "$work16/lib.jar"
out16=$(cd "$work16" && env -u VINEFLOWER_JAR FERNFLOWER_JAR_PATH="/nonexistent/whatever.jar" \
        "${BASH:-bash}" "$SCRIPT" lib.jar 2>&1)
status16=$?

assert_equals "$status16" "1" \
  "[all] D16: a set FERNFLOWER_JAR_PATH exits non-zero (renamed to VINEFLOWER_JAR in 2.0.0)"
assert_contains "$out16" "FERNFLOWER_JAR_PATH 已於 2.0.0 更名為 VINEFLOWER_JAR" \
  "[all] D16: a set FERNFLOWER_JAR_PATH prints the exact migration hint"

# --- D11 (review round 1, C1): decompile.ps1's -Engine vineflower
# refusal must exit non-zero, not announce failure and then print a
# success banner. Found by actually running it: Invoke-DecompileSingle
# used to discard Invoke-Vineflower's boolean return value as a bare
# statement, so the refusal's $false never reached the script's exit
# code and execution fell through to "=== Decompilation complete ===".
# Only runs where pwsh/powershell exists.
PWSH_BIN=""
if command -v pwsh >/dev/null 2>&1; then
  PWSH_BIN="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  PWSH_BIN="powershell"
fi

if [ -z "$PWSH_BIN" ]; then
  echo "SKIP: neither pwsh nor powershell found on PATH; skipping the [win] decompile.ps1 refusal-exit-code check."
else
  PS1_SCRIPT="$SCRIPT_DIR/decompile.ps1"
  work11=$(new_tmpdir)
  touch "$work11/app.apk"
  native_work11="$work11"
  native_ps1="$PS1_SCRIPT"
  if command -v cygpath >/dev/null 2>&1; then
    native_work11=$(cygpath -w "$work11")
    native_ps1=$(cygpath -w "$PS1_SCRIPT")
  fi

  "$PWSH_BIN" -NoProfile -NonInteractive -File "$native_ps1" \
    -Engine vineflower "$native_work11\app.apk" >"$work11/ps-out.txt" 2>&1
  ps11_status=$?
  ps11_out=$(cat "$work11/ps-out.txt")

  assert_equals "$ps11_status" "1" \
    "[win] D11: decompile.ps1 -Engine vineflower on a .apk exits non-zero"
  assert_not_contains "$ps11_out" "=== Decompilation complete ===" \
    "[win] D11: decompile.ps1 does not print the success banner after the vineflower refusal"

  # --- D13 (review round 1, C2): decompile.ps1's print_structure
  # crowding-out fix must actually work with a RELATIVE output directory,
  # which is what $Output defaults to on every real invocation. Show-
  # Structure used to strip "$SrcDir\" as a prefix without first
  # resolving $SrcDir to absolute, so the strip silently no-op'd, every
  # entry kept its full absolute path, and ($_ -split '\\')[0] was "C:"
  # for every entry — collapsing the whole named-vs-single-letter split
  # into one bucket. Reproduces the exact fixture used for the bash D6
  # test: a real package (com/example/network) alongside a single
  # top-level letter ("a") wide enough (25 subdirectories) to fill the
  # cap on its own.
  work13=$(new_tmpdir)
  bin13=$(new_tmpdir)
  cat > "$bin13/jadx.cmd" <<'CMD'
@echo off
setlocal enabledelayedexpansion
set OUT=
:loop
if "%~1"=="" goto done
if "%PREV%"=="-d" set OUT=%~1
set PREV=%~1
shift
goto loop
:done
mkdir "%OUT%\sources\com\example\network" 2>nul
for /L %%i in (1,1,25) do mkdir "%OUT%\sources\a\sub%%i" 2>nul
echo class A {} > "%OUT%\sources\com\example\network\A.java"
exit /b 0
CMD

  touch "$work13/app.apk"
  native_ps1_13="$SCRIPT_DIR/decompile.ps1"
  if command -v cygpath >/dev/null 2>&1; then
    native_ps1_13=$(cygpath -w "$SCRIPT_DIR/decompile.ps1")
  fi

  # Filter PATH to strip any directory containing a real jadx, same
  # reasoning as D10 above: this machine may have a real jadx installed,
  # and we need the stub to be unambiguously the one Resolve-Tool finds.
  path13=""
  _p13_oldifs="$IFS"
  IFS=':'
  for _p13_dir in $PATH; do
    IFS="$_p13_oldifs"
    if [ -n "$_p13_dir" ] && [ ! -f "$_p13_dir/jadx" ] && [ ! -f "$_p13_dir/jadx.bat" ] && [ ! -f "$_p13_dir/jadx.cmd" ]; then
      path13="${path13:+$path13:}$_p13_dir"
    fi
    IFS=':'
  done
  IFS="$_p13_oldifs"

  # cwd = work13 with no -Output given: $Output defaults to the relative
  # "app-decompiled", exactly the case C2 found broken.
  out13=$(cd "$work13" && PATH="$bin13:$path13" \
          "$PWSH_BIN" -NoProfile -NonInteractive -File "$native_ps1_13" app.apk 2>&1)

  assert_contains "$out13" "com\\example\\network" \
    "[win] D13: decompile.ps1 print_structure surfaces com\\example\\network with the default relative output dir"
  assert_contains "$out13" "more (showing" \
    "[win] D13: decompile.ps1 print_structure states the true total when the cap truncates the listing"

  # --- D14 (review round 1, I4): decompile.ps1 must find jadx via a
  # tools.psv candidate path (Resolve-Tool) when nothing is on PATH, the
  # PowerShell counterpart to bash D10 above. Invoke-Jadx used to do a
  # bare Get-Command jadx, which is exactly what misses a jadx that
  # install-dep.ps1 just placed at one of tools.psv's candidate paths.
  home14=$(new_tmpdir)
  mkdir -p "$home14/.local/share/jadx/bin"
  cat > "$home14/.local/share/jadx/bin/jadx.bat" <<'BAT'
@echo off
setlocal enabledelayedexpansion
set OUT=
:loop
if "%~1"=="" goto done
if "%PREV%"=="-d" set OUT=%~1
set PREV=%~1
shift
goto loop
:done
mkdir "%OUT%\sources" 2>nul
echo class A {} > "%OUT%\sources\A.java"
echo JADX_PS_CANDIDATE_RAN
exit /b 0
BAT

  work14=$(new_tmpdir)
  touch "$work14/app.apk"
  native_ps1_14="$SCRIPT_DIR/decompile.ps1"
  native_home14="$home14"
  if command -v cygpath >/dev/null 2>&1; then
    native_ps1_14=$(cygpath -w "$SCRIPT_DIR/decompile.ps1")
    native_home14=$(cygpath -w "$home14")
  fi

  path14=""
  _p14_oldifs="$IFS"
  IFS=':'
  for _p14_dir in $PATH; do
    IFS="$_p14_oldifs"
    if [ -n "$_p14_dir" ] && [ ! -f "$_p14_dir/jadx" ] && [ ! -f "$_p14_dir/jadx.bat" ] && [ ! -f "$_p14_dir/jadx.cmd" ]; then
      path14="${path14:+$path14:}$_p14_dir"
    fi
    IFS=':'
  done
  IFS="$_p14_oldifs"

  out14=$(cd "$work14" && USERPROFILE="$native_home14" PATH="$path14" \
          env -u JADX_BIN "$PWSH_BIN" -NoProfile -NonInteractive -File "$native_ps1_14" app.apk 2>&1)

  assert_contains "$out14" "JADX_PS_CANDIDATE_RAN" \
    "[win] D14: decompile.ps1 finds jadx via a tools.psv candidate path (USERPROFILE) when nothing is on PATH"

  # --- D17 (Task 8): decompile.ps1's -Engine fernflower must print the
  # same migration hint as bash D15 and exit non-zero, not fall through to
  # the generic "Unknown engine" message or (worse) still work under the
  # old name.
  work17=$(new_tmpdir)
  touch "$work17/lib.jar"
  native_work17="$work17"
  native_ps1_17="$SCRIPT_DIR/decompile.ps1"
  if command -v cygpath >/dev/null 2>&1; then
    native_work17=$(cygpath -w "$work17")
    native_ps1_17=$(cygpath -w "$SCRIPT_DIR/decompile.ps1")
  fi

  env -u FERNFLOWER_JAR_PATH -u VINEFLOWER_JAR "$PWSH_BIN" -NoProfile -NonInteractive -File "$native_ps1_17" \
    -Engine fernflower "$native_work17\lib.jar" >"$work17/ps-out.txt" 2>&1
  ps17_status=$?
  ps17_out=$(cat "$work17/ps-out.txt")

  assert_equals "$ps17_status" "1" \
    "[win] D17: decompile.ps1 -Engine fernflower exits non-zero (renamed to -Engine vineflower in 2.0.0)"
  assert_contains "$ps17_out" "--engine fernflower 已於 2.0.0 更名為 --engine vineflower" \
    "[win] D17: decompile.ps1 -Engine fernflower prints the exact migration hint"

  # --- D18 (Task 8): a stale FERNFLOWER_JAR_PATH in the environment must
  # be caught the same way on the PowerShell side, regardless of -Engine.
  work18=$(new_tmpdir)
  touch "$work18/lib.jar"
  native_work18="$work18"
  native_ps1_18="$SCRIPT_DIR/decompile.ps1"
  if command -v cygpath >/dev/null 2>&1; then
    native_work18=$(cygpath -w "$work18")
    native_ps1_18=$(cygpath -w "$SCRIPT_DIR/decompile.ps1")
  fi

  env -u VINEFLOWER_JAR FERNFLOWER_JAR_PATH="C:\nonexistent\whatever.jar" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$native_ps1_18" "$native_work18\lib.jar" \
    >"$work18/ps-out.txt" 2>&1
  ps18_status=$?
  ps18_out=$(cat "$work18/ps-out.txt")

  assert_equals "$ps18_status" "1" \
    "[win] D18: decompile.ps1 exits non-zero when FERNFLOWER_JAR_PATH is set (renamed to VINEFLOWER_JAR in 2.0.0)"
  assert_contains "$ps18_out" "FERNFLOWER_JAR_PATH 已於 2.0.0 更名為 VINEFLOWER_JAR" \
    "[win] D18: decompile.ps1 prints the exact migration hint when FERNFLOWER_JAR_PATH is set"
fi

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
