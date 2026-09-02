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
      env -u FERNFLOWER_JAR_PATH "${BASH:-bash}" "$SCRIPT" --engine fernflower lib.jar 2>&1)

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
       env -u FERNFLOWER_JAR_PATH "${BASH:-bash}" "$SCRIPT" --engine fernflower lib.jar 2>&1)

assert_contains "$out2" "VINEFLOWER_CLI_ARGV" \
  "D2: decompile uses a vineflower CLI found on PATH"
assert_not_contains "$out2" "JAVA_SHOULD_NOT_RUN" \
  "D2: decompile does not fall back to java -jar when a CLI is present"

# --- D3: the XAPK temp dir must be removed even when decompilation fails ---
# The trap must fire on any failure path, including unzip failure before APKs are found.
# Create a dummy invalid XAPK (no archiver dependency, works on all platforms).
work3=$(new_tmpdir)
echo "not a zip" > "$work3/bundle.xapk"

before=$(ls -d "${TMPDIR:-/tmp}"/xapk-extract-* 2>/dev/null | wc -l | tr -d ' ')
output=$(cd "$work3" && "${BASH:-bash}" "$SCRIPT" bundle.xapk 2>&1) || true
after=$(ls -d "${TMPDIR:-/tmp}"/xapk-extract-* 2>/dev/null | wc -l | tr -d ' ')

assert_contains "$output" "=== Extracting XAPK archive ===" \
  "D3: decompile reaches XAPK extraction (code path exercised)"
assert_equals "$after" "$before" \
  "D3: no xapk-extract-* temp dir is left behind on unzip failure"

# --- D3 (signal half): SIGTERM sent while decompile.sh is mid-extraction
# must also remove the temp dir. The trap above only proves the EXIT path;
# EXIT INT TERM was specifically added because EXIT alone does not fire
# when the process is killed by an untrapped signal — a bare `trap ... EXIT`
# never runs at all in that case (nothing to "fall through" to), it isn't
# just "runs late". A stub `unzip` that sleeps gives a real window to
# deliver SIGTERM while XAPK_EXTRACTED_DIR still exists and the process is
# still alive; the wait afterwards is generous because a genuinely-trapped
# signal is deferred by bash until the current foreground command (the
# sleeping stub) finishes, not delivered instantly.
work4=$(new_tmpdir)
echo "not a zip" > "$work4/bundle.xapk"
bin4=$(new_tmpdir)
make_stub_bin "$bin4" unzip 'sleep 3
exit 1'

# Snapshot pre-existing xapk-extract-* dirs first: run-mutations.sh invokes
# this whole suite many times in the same environment, so a dir left over
# by an earlier iteration (possibly the very defect this test is proving
# exists) must not be mistaken for the one this invocation creates.
before_dirs=$(ls -d "${TMPDIR:-/tmp}"/xapk-extract-* 2>/dev/null || true)

( cd "$work4" && PATH="$bin4:$PATH" exec "${BASH:-bash}" "$SCRIPT" bundle.xapk ) >"$work4/sigterm-out.log" 2>&1 &
sig_pid=$!

sleep 1
sig_dir=""
for d in "${TMPDIR:-/tmp}"/xapk-extract-*; do
  [ -d "$d" ] || continue
  case "$before_dirs" in
    *"$d"*) ;;
    *) sig_dir="$d" ;;
  esac
done

if [ -z "$sig_dir" ]; then
  _fail "D3 (signal): SIGTERM mid-XAPK-extraction still removes the temp dir" \
    "setup: no xapk-extract-* temp dir appeared before the signal was sent"
  kill -TERM "$sig_pid" 2>/dev/null || true
else
  kill -TERM "$sig_pid" 2>/dev/null || true
  waited=0
  while kill -0 "$sig_pid" 2>/dev/null && [ "$waited" -lt 8 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ -d "$sig_dir" ]; then
    assert_equals "exists" "gone" \
      "D3 (signal): SIGTERM mid-XAPK-extraction still removes the temp dir"
  else
    assert_equals "gone" "gone" \
      "D3 (signal): SIGTERM mid-XAPK-extraction still removes the temp dir"
  fi
fi
# Make sure nothing from this sub-test is still running before we exit.
kill -0 "$sig_pid" 2>/dev/null && kill -KILL "$sig_pid" 2>/dev/null || true

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
