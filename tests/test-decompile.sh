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

# D3 ("the XAPK temp dir must be removed even when decompilation fails") is
# gone, not merely moved: 2.0.0 deletes the hand-rolled XAPK extraction
# entirely (mktemp -d, its guarding trap, the manifest/OBB handling, and
# the per-APK loop) in favor of handing .xapk straight to jadx, which
# understands the format natively. There is no longer a temp dir for a
# trap to clean up, so the code this test guarded no longer exists. It is
# deleted here — along with tests/mutations/d3-no-trap.mutation, which
# targeted the same trap — rather than left in place where it could only
# ever pass trivially.

# --- D5: the fernflower/vineflower engine must refuse non-JVM-bytecode
# input now that dex2jar has been removed, rather than silently doing
# nothing useful or crashing deeper in the pipeline. ---
work5=$(new_tmpdir)
touch "$work5/app.apk"

out5=$(cd "$work5" && "${BASH:-bash}" "$SCRIPT" --engine fernflower app.apk 2>&1)
status5=$?

assert_equals "$status5" "1" \
  "[all] D5: --engine fernflower on a .apk exits non-zero (dex2jar removed, no DEX support)"
assert_contains "$out5" "only decompiles .jar, .aar, and .class" \
  "[all] D5: --engine fernflower refusal names the accepted extensions"
assert_contains "$out5" "dex2jar conversion has been removed" \
  "[all] D5: --engine fernflower refusal explains WHY .apk is rejected (not just that it is)"

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
assert_contains "$out8" "bundle.xapk" \
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

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
