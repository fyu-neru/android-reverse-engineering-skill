#!/usr/bin/env bash
# test-tools-psv.sh — reader tests and cross-reader consistency for
# tools.psv, tools.sh and Tools.ps1 (Task 1, commit 5f55944).
#
# This is the highest-value artifact of the 2.0.0 release: the two readers
# must agree exactly, or a divergence recreates the class of bug the whole
# resolution-layer effort exists to eliminate, invisible until someone on
# the other platform hits it.
#
# See docs/superpowers/specs/2026-09-02-toolchain-modernization-design.md
# §6.2 for the vacuous-test shapes this file must not fall into, and §6.3
# for which of these groups fails on which platform when its guarded
# defect is reintroduced. Every assertion label below carries a platform
# marker ([all]/[win]) per that table.
#
# bash 3.2 compatible: no associative arrays, no case-modification
# expansions, no mapfile/readarray, no namerefs.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/lib"
TOOLS_SH="$LIB_DIR/tools.sh"
TOOLS_PS1="$LIB_DIR/Tools.ps1"
TOOLS_PSV="$LIB_DIR/tools.psv"
PLUGIN_ROOT="$REPO_ROOT/plugins/android-reverse-engineering"

# to_native_path <posix-path>
# Converts an MSYS/Git-Bash path (e.g. /d/foo) to Windows drive-letter form
# (via cygpath -w) so the SAME literal path string can be embedded in a
# fixture file and handed to both this bash process and a native pwsh.exe
# child process with no translation surprises (a bare "/d/foo" means
# nothing to a native Win32 filesystem call). On any platform with no
# cygpath (Linux, macOS, native PowerShell there too) the path is already
# in a form both sides understand, so it is returned unchanged.
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

# =====================================================================
# Group 1 — non-empty precondition before comparing (§6.2 shape 1: "both
# sides returned empty so they match" is the single most common way this
# class of test passes vacuously).
# =====================================================================
expected_purpose="Primary decompiler for APK, DEX, AAB, XAPK and APKM"
if [ -n "$expected_purpose" ]; then _exp_state=nonempty; else _exp_state=empty; fi
assert_equals "$_exp_state" "nonempty" \
  "[all] precondition: expected jadx purpose value is non-empty before comparing to the reader's output"

bash_purpose=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_field jadx purpose')
assert_equals "$bash_purpose" "$expected_purpose" \
  "[all] tools.sh: tool_field jadx purpose returns the expected non-empty value from the real tools.psv"

# =====================================================================
# Fixture for groups 2-4: a private fake plugin root so these tests do
# not depend on (or corrupt) the real tools.psv.
# =====================================================================
order_root=$(new_tmpdir)
order_lib="$order_root/skills/android-reverse-engineering/scripts/lib"
mkdir -p "$order_lib"
cat > "$order_lib/tools.psv" <<'PSV'
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
# comment row: must not be counted as a data row by either reader
widget|required|all|path|widget-cli-stub-zzz|WIDGET_ENV|{HOME}/widget-candidate|-|-|-|-|Widget test tool

gadget|optional|all|jar|gadget-cli-stub-zzz|GADGET_ENV|{HOME}/gadget-candidate.jar|-|-|-|-|Gadget test tool
sprocket|optional|all|path|sprocket-cli-stub-zzz|-|{HOME}/sprocket-candidate|-|-|-|-|Sprocket test tool
java|required|all|path|java-cli-stub-zzz|JAVA_ENV|{HOME}/java-candidate|-|-|-|-|Java stub for tool_argv jar-kind test
PSV

fixhome=$(new_tmpdir)
touch "$fixhome/widget-candidate" "$fixhome/widget-env-target" \
      "$fixhome/gadget-candidate.jar" "$fixhome/java-candidate"

stubbin=$(new_tmpdir)
make_stub_bin "$stubbin" widget-cli-stub-zzz 'exit 0'
emptybin=$(new_tmpdir)

# =====================================================================
# Group 2 — parsed row count matches the fixture's non-comment, non-blank
# data rows (§6.2 shape 2: an unloaded fixture makes both sides iterate
# zero rows, which reads as agreement unless the count itself is checked
# against a known-nonzero expectation first).
# =====================================================================
expected_rows=4
if [ "$expected_rows" -gt 0 ]; then _rows_state=nonzero; else _rows_state=zero; fi
assert_equals "$_rows_state" "nonzero" \
  "[all] precondition: expected fixture row count is non-zero before comparing"

bash_ids=$(CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_list')
actual_rows=$(printf '%s\n' "$bash_ids" | grep -c .)
assert_equals "$actual_rows" "$expected_rows" \
  "[all] tool_list row count equals the fixture's non-comment, non-blank data row count (fixture-load guard)"

bash_ids_sorted=$(printf '%s\n' "$bash_ids" | sort)
assert_equals "$bash_ids_sorted" "$(printf 'gadget\njava\nsprocket\nwidget\n')" \
  "[all] tool_list returns exactly the fixture's ids (not merely the right count)"

# =====================================================================
# Group 3 — resolution order: four cases, using new_tmpdir for a fake
# HOME/jar and make_stub_bin for a fake PATH CLI.
# =====================================================================

# Case 1: env override present and file exists -> wins over a PATH CLI
# that ALSO exists (the only case sensitive to which check runs first).
out1=$(HOME="$fixhome" WIDGET_ENV="$fixhome/widget-env-target" \
  PATH="$stubbin:$PATH" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_resolve widget')
assert_equals "$out1" "$fixhome/widget-env-target" \
  "[all] resolution order: env override wins over PATH probe and candidates when set and file exists"

# Case 2: env override unset, PATH has the CLI -> CLI wins over candidates.
out2=$(HOME="$fixhome" PATH="$stubbin:$PATH" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_resolve widget')
assert_equals "$out2" "$stubbin/widget-cli-stub-zzz" \
  "[all] resolution order: PATH probe wins over candidate paths when there is no env override"

# Case 3: neither env override nor PATH CLI -> falls back to candidates.
out3=$(HOME="$fixhome" PATH="$emptybin" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_resolve widget')
assert_equals "$out3" "$fixhome/widget-candidate" \
  "[all] resolution order: candidate path is used when neither env override nor PATH probe apply"

# Case 4: env override points at a file that does not exist -> skipped,
# resolution continues down the chain rather than failing outright.
out4=$(HOME="$fixhome" WIDGET_ENV="$fixhome/widget-env-target-MISSING" \
  PATH="$stubbin:$PATH" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_resolve widget')
assert_equals "$out4" "$stubbin/widget-cli-stub-zzz" \
  "[all] resolution order: a non-existent env override target is skipped, not treated as fatal"

# =====================================================================
# Group 4 — tool_argv: kind=path is a one-element TOOL_ARGV; kind=jar is
# (java -jar <path>), where java itself is resolved via tool_resolve
# rather than hard-coded as a literal.
# =====================================================================
argv_path_out=$(HOME="$fixhome" PATH="$emptybin" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_argv widget && printf "%s\n" "${#TOOL_ARGV[@]}" "${TOOL_ARGV[@]}"')
argv_path_count=$(printf '%s\n' "$argv_path_out" | sed -n '1p')
argv_path_elem0=$(printf '%s\n' "$argv_path_out" | sed -n '2p')
assert_equals "$argv_path_count" "1" \
  "[all] tool_argv: kind=path produces a single-element TOOL_ARGV"
assert_equals "$argv_path_elem0" "$fixhome/widget-candidate" \
  "[all] tool_argv: kind=path's single element is the resolved tool path"

argv_jar_out=$(HOME="$fixhome" PATH="$emptybin" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_argv gadget && printf "%s\n" "${#TOOL_ARGV[@]}" "${TOOL_ARGV[@]}"')
argv_jar_count=$(printf '%s\n' "$argv_jar_out" | sed -n '1p')
argv_jar_elem0=$(printf '%s\n' "$argv_jar_out" | sed -n '2p')
argv_jar_elem1=$(printf '%s\n' "$argv_jar_out" | sed -n '3p')
argv_jar_elem2=$(printf '%s\n' "$argv_jar_out" | sed -n '4p')
assert_equals "$argv_jar_count" "3" \
  "[all] tool_argv: kind=jar produces a three-element TOOL_ARGV (java -jar <path>)"
assert_equals "$argv_jar_elem0" "$fixhome/java-candidate" \
  "[all] tool_argv: kind=jar's java element comes from tool_resolve java, not a hard-coded 'java' literal"
assert_equals "$argv_jar_elem1" "-jar" \
  "[all] tool_argv: kind=jar's second element is the literal -jar flag"
assert_equals "$argv_jar_elem2" "$fixhome/gadget-candidate.jar" \
  "[all] tool_argv: kind=jar's third element is the resolved jar path"

# =====================================================================
# Group 5 — static: the two readers reference an identical set of field
# names. This is the one that fails on every platform (§6.3): it is a
# pure text comparison of the two source files, no interpreter needed.
# =====================================================================
bash_fields=$(grep -oE 'tool_field "\$[A-Za-z_][A-Za-z0-9_]*" [A-Za-z_][A-Za-z0-9_]*' "$TOOLS_SH" \
  | awk '{print $NF}' | sort -u)
ps_fields=$(grep -oE "\-Column '[A-Za-z_][A-Za-z0-9_]*'" "$TOOLS_PS1" \
  | sed -E "s/-Column '([A-Za-z_][A-Za-z0-9_]*)'/\1/" | sort -u)

if [ -n "$bash_fields" ]; then _bf_state=nonempty; else _bf_state=empty; fi
assert_equals "$_bf_state" "nonempty" \
  "[all] precondition: tools.sh field-name extraction found at least one tool_field reference"
if [ -n "$ps_fields" ]; then _pf_state=nonempty; else _pf_state=empty; fi
assert_equals "$_pf_state" "nonempty" \
  "[all] precondition: Tools.ps1 field-name extraction found at least one Get-ToolField reference"

assert_equals "$bash_fields" "$ps_fields" \
  "[all] static: tools.sh and Tools.ps1 reference the exact same set of tool_field/Get-ToolField column names"

# =====================================================================
# Group 6 — static: tools.psv's header matches the union of fields the
# two readers use. A header column no reader consumes at all (not even a
# documented future consumer), or a field a reader uses that the header
# lacks, must both fail.
#
# Design note: tools.psv (Task 1) deliberately carries columns neither
# resolution reader touches yet — platform, gh_repo, asset, pin,
# pin_digest are reserved for install-dep.sh/check-deps.sh migrations
# later in the 2.0.0 roadmap (design doc §7), and purpose is
# documentation-only by the PSV's own header comment and is never meant
# to be machine-consumed. Those are listed explicitly below so this test
# still catches real drift (a typo'd column, a column silently dropped by
# one reader) without permanently red-flagging intentional forward
# columns.
# =====================================================================
header_line=$(head -1 "$TOOLS_PSV")
header_fields=$(printf '%s' "$header_line" | tr '|' '\n' | grep -vFx 'id' | sort -u)
reserved_fields=$(printf '%s\n' platform gh_repo asset pin pin_digest purpose | sort -u)
used_fields=$(printf '%s\n%s\n' "$bash_fields" "$ps_fields" | sort -u)

missing_from_header=$(comm -23 <(printf '%s\n' "$used_fields") <(printf '%s\n' "$header_fields"))
assert_equals "$missing_from_header" "" \
  "[all] static: tools.psv header contains every field name referenced by tool_field/Get-ToolField"

allowed_fields=$(printf '%s\n%s\n' "$used_fields" "$reserved_fields" | sort -u)
extra_in_header=$(comm -23 <(printf '%s\n' "$header_fields") <(printf '%s\n' "$allowed_fields"))
assert_equals "$extra_in_header" "" \
  "[all] static: every tools.psv header column is either used by a reader or an explicitly reserved future/documentation column"

# =====================================================================
# Group 7 — PowerShell runtime consistency: the same fixture fed to both
# readers, compared verbatim (no trim/case-fold/sort — §6.2 shape 4).
# Only runs where pwsh or powershell exists; SKIP is visibly distinct
# from a passing assertion (§6.2 shape 3).
# =====================================================================
PWSH_BIN=""
if command -v pwsh >/dev/null 2>&1; then
  PWSH_BIN="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  PWSH_BIN="powershell"
fi

if [ -z "$PWSH_BIN" ]; then
  echo "SKIP: neither pwsh nor powershell found on PATH; skipping the [win] runtime cross-reader consistency group."
else
  cross_root=$(new_tmpdir)
  cross_lib="$cross_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$cross_lib"
  cross_home=$(new_tmpdir)
  native_home=$(to_native_path "$cross_home")

  cat > "$cross_lib/tools.psv" <<PSV
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
rone|required|all|path|-|RONE_ENV|$native_home/rone-candidate|-|-|-|-|Cross-reader env-priority test
rtwo|optional|all|jar|-|-|$native_home/rtwo-candidate.jar|-|-|-|-|Cross-reader candidate-only jar test
rthree|required|all|path|-|RTHREE_ENV|$native_home/rthree-candidate|-|-|-|-|Cross-reader env-invalid-falls-through test
rfour|optional|all|path|-|-|$native_home/rfour-candidate-MISSING|-|-|-|-|Cross-reader tool-missing test
PSV

  touch "$cross_home/rone-env-target" "$cross_home/rone-candidate" \
        "$cross_home/rtwo-candidate.jar" "$cross_home/rthree-candidate"
  # rfour-candidate-MISSING deliberately not created.

  rone_env_native="$native_home/rone-env-target"
  rthree_env_missing_native="$native_home/rthree-env-target-MISSING"
  native_cross_root=$(to_native_path "$cross_root")
  native_tools_ps1=$(to_native_path "$TOOLS_PS1")

  bash_cross_out=$(CLAUDE_PLUGIN_ROOT="$cross_root" TOOLS_SH_PATH="$TOOLS_SH" \
    RONE_ENV="$rone_env_native" RTHREE_ENV="$rthree_env_missing_native" \
    "${BASH:-bash}" -c '
      . "$TOOLS_SH_PATH"
      printf "LIST=%s\n" "$(tool_list | tr "\n" ",")"
      for id in rone rtwo rthree rfour; do
        for col in kind env_override candidates required; do
          v=$(tool_field "$id" "$col")
          if [ $? -ne 0 ]; then v="<NULL>"; fi
          printf "FIELD=%s|%s|%s\n" "$id" "$col" "$v"
        done
        r=$(tool_resolve "$id")
        if [ $? -ne 0 ]; then r="<NULL>"; fi
        printf "RESOLVE=%s|%s\n" "$id" "$r"
      done
    ')

  ps_script_dir=$(new_tmpdir)
  ps_script="$ps_script_dir/cross-check.ps1"
  cat > "$ps_script" <<'EOF'
$ErrorActionPreference = 'Stop'
. $env:TOOLS_PS1_PATH
$ids = Get-ToolList
Write-Output ("LIST=" + (($ids -join ',') + ','))
foreach ($id in @('rone', 'rtwo', 'rthree', 'rfour')) {
    foreach ($col in @('kind', 'env_override', 'candidates', 'required')) {
        $v = Get-ToolField -Id $id -Column $col
        if ($null -eq $v) { $v = '<NULL>' }
        Write-Output ("FIELD=" + $id + "|" + $col + "|" + $v)
    }
    $r = Resolve-Tool -Id $id
    if ($null -eq $r) {
        Write-Output ("RESOLVE=" + $id + "|<NULL>")
    } else {
        Write-Output ("RESOLVE=" + $id + "|" + $r.Path)
    }
}
EOF

  # PowerShell's host writes CRLF line endings even when the *content* of
  # each Write-Output line is pure ASCII; stripping the trailing \r here
  # is normalizing the transport's line-ending artifact, not the field
  # data itself, so it does not fall into the over-normalization trap
  # (§6.2 shape 4) — a real divergence in a field VALUE survives this.
  ps_cross_out=$(CLAUDE_PLUGIN_ROOT="$native_cross_root" TOOLS_PS1_PATH="$native_tools_ps1" \
    RONE_ENV="$rone_env_native" RTHREE_ENV="$rthree_env_missing_native" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$ps_script" 2>&1 | tr -d '\r')

  # --- preconditions (§6.2 shapes 1 & 2), asserted BEFORE the full-output
  # comparison, each against a specific known-non-empty expected value ---
  assert_contains "$bash_cross_out" "LIST=rone,rtwo,rthree,rfour," \
    "[win] precondition: tools.sh loaded the cross-reader fixture (tool_list returns the expected 4 ids, not zero)"
  assert_contains "$ps_cross_out" "LIST=rone,rtwo,rthree,rfour," \
    "[win] precondition: Tools.ps1 loaded the cross-reader fixture (Get-ToolList returns the expected 4 ids, not zero)"
  assert_contains "$bash_cross_out" "RESOLVE=rone|$rone_env_native" \
    "[win] precondition: tools.sh resolves rone via env override to the expected non-empty path"
  assert_contains "$ps_cross_out" "RESOLVE=rone|$rone_env_native" \
    "[win] precondition: Tools.ps1 resolves rone via env override to the expected non-empty path"
  assert_contains "$bash_cross_out" "RESOLVE=rfour|<NULL>" \
    "[win] precondition: tools.sh reports rfour (no env, no probe, missing candidate) as unresolved, not a false match"
  assert_contains "$ps_cross_out" "RESOLVE=rfour|<NULL>" \
    "[win] precondition: Tools.ps1 reports rfour (no env, no probe, missing candidate) as unresolved, not a false match"

  # --- the actual cross-reader comparison: verbatim, no normalization ---
  assert_equals "$bash_cross_out" "$ps_cross_out" \
    "[win] runtime cross-reader consistency: tool_list/tool_field/tool_resolve output from tools.sh exactly matches Get-ToolList/Get-ToolField/Resolve-Tool output from Tools.ps1 on the same fixture"
fi

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
