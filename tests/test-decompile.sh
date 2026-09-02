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
out=$(cd "$work" && PATH="$bin:$PATH" bash "$SCRIPT" app.apk 2>&1)

assert_contains "$out" "com/example/network" \
  "D4: print_structure lists nested packages without find -printf"
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
      env -u FERNFLOWER_JAR_PATH bash "$SCRIPT" --engine fernflower lib.jar 2>&1)

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
       env -u FERNFLOWER_JAR_PATH bash "$SCRIPT" --engine fernflower lib.jar 2>&1)

assert_contains "$out2" "VINEFLOWER_CLI_ARGV" \
  "D2: decompile uses a vineflower CLI found on PATH"
assert_not_contains "$out2" "JAVA_SHOULD_NOT_RUN" \
  "D2: decompile does not fall back to java -jar when a CLI is present"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
