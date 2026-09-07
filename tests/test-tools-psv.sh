#!/usr/bin/env bash
# test-tools-psv.sh — reader tests and cross-reader consistency for
# tools.psv, tools.sh and Tools.ps1 (Task 1, commit 5f55944; fix round 1
# on Tasks 1+2 hardened tools.sh/Tools.ps1's parsing rules themselves;
# fix round 1 on Task 3 restored the dropped Windows jadx candidates and
# widened Group 6's field-usage scan to cover consumer scripts, not just
# the two reader files).
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
# Fixture for groups 2-4b: a private fake plugin root so these tests do
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
gadgetcli|optional|all|jar|gadgetcli-stub-zzz|-|{HOME}/gadgetcli-candidate.jar|-|-|-|-|Gadget CLI test: jar-kind tool actually found via PATH probe
PSV

fixhome=$(new_tmpdir)
touch "$fixhome/widget-candidate" "$fixhome/widget-env-target" \
      "$fixhome/gadget-candidate.jar" "$fixhome/java-candidate" \
      "$fixhome/gadgetcli-candidate.jar"

stubbin=$(new_tmpdir)
make_stub_bin "$stubbin" widget-cli-stub-zzz 'exit 0'
make_stub_bin "$stubbin" gadgetcli-stub-zzz 'exit 0'
emptybin=$(new_tmpdir)

# =====================================================================
# Group 2 — parsed row count matches the fixture's non-comment, non-blank
# data rows (§6.2 shape 2: an unloaded fixture makes both sides iterate
# zero rows, which reads as agreement unless the count itself is checked
# against a known-nonzero expectation first).
# =====================================================================
expected_rows=5
if [ "$expected_rows" -gt 0 ]; then _rows_state=nonzero; else _rows_state=zero; fi
assert_equals "$_rows_state" "nonzero" \
  "[all] precondition: expected fixture row count is non-zero before comparing"

bash_ids=$(CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_list')
actual_rows=$(printf '%s\n' "$bash_ids" | grep -c .)
assert_equals "$actual_rows" "$expected_rows" \
  "[all] tool_list row count equals the fixture's non-comment, non-blank data row count (fixture-load guard)"

bash_ids_sorted=$(printf '%s\n' "$bash_ids" | sort)
assert_equals "$bash_ids_sorted" "$(printf 'gadget\ngadgetcli\njava\nsprocket\nwidget\n')" \
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

# --- Task 4 review C1 root cause: a kind=jar tool (per tools.psv) that is
# actually found via the PATH probe as a real CLI (e.g. a package
# manager's launcher script) must be run directly - a single-element
# TOOL_ARGV - not wrapped in `java -jar <that CLI's path>`, which fails
# immediately. Before this was fixed, tool_argv built TOOL_ARGV purely
# from the static PSV kind column regardless of which resolution stage
# actually matched, so this exact case produced `java -jar
# <stubbin>/gadgetcli-stub-zzz`. This is the reader-level test that was
# missing: only a bash-only decompile.sh regression test (test-decompile.sh
# D2) caught the original bug, and nothing at this level would catch a
# regression on its own. ---
argv_probejar_out=$(HOME="$fixhome" PATH="$stubbin:$PATH" CLAUDE_PLUGIN_ROOT="$order_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_argv gadgetcli && printf "%s\n" "${#TOOL_ARGV[@]}" "${TOOL_ARGV[@]}"')
argv_probejar_count=$(printf '%s\n' "$argv_probejar_out" | sed -n '1p')
argv_probejar_elem0=$(printf '%s\n' "$argv_probejar_out" | sed -n '2p')
assert_equals "$argv_probejar_count" "1" \
  "[all] tool_argv: kind=jar found via PATH probe produces a single-element TOOL_ARGV (direct exec, not java -jar)"
assert_equals "$argv_probejar_elem0" "$stubbin/gadgetcli-stub-zzz" \
  "[all] tool_argv: kind=jar's probe-matched element is the CLI found on PATH, not the jar candidate"

# =====================================================================
# Group 4b — glob safety (fix round 1, Finding 1): a PSV field value that
# contains a shell glob character must not be pathname-expanded while
# tools.sh splits the line. Reproduced pre-fix: with IFS='|' and an
# unquoted `for f in $line`, bash applies pathname expansion to each
# resulting word — a probe value of 'zzz-glob-probe-*' silently became
# two words when files matching that pattern existed in cwd, shifting
# every column after it by one. This test seeds exactly such files in a
# dedicated cwd and checks a column several positions later (pin) reads
# its own value, not a neighbor's.
# =====================================================================
globdir=$(new_tmpdir)
touch "$globdir/zzz-glob-probe-A" "$globdir/zzz-glob-probe-B"

glob_root=$(new_tmpdir)
glob_lib="$glob_root/skills/android-reverse-engineering/scripts/lib"
mkdir -p "$glob_lib"
cat > "$glob_lib/tools.psv" <<'PSV'
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
star|required|all|path|zzz-glob-probe-*|ENVOVERRIDE-STAR|CANDIDATES-STAR|GHREPO-STAR|ASSET-STAR|PINVALUE-STAR|PINDIGEST-STAR|PURPOSE-STAR
PSV

glob_out=$(cd "$globdir" && CLAUDE_PLUGIN_ROOT="$glob_root" TOOLS_SH_PATH="$TOOLS_SH" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_field star pin')
assert_equals "$glob_out" "PINVALUE-STAR" \
  "[all] tool_field: a field value containing '*' is not pathname-expanded even when matching files exist in cwd (glob safety)"

# =====================================================================
# Group 5 — static: the two readers reference an identical set of field
# names. This is the one that fails on every platform (§6.3): it is a
# pure text comparison of the two source files, no interpreter needed.
# =====================================================================
bash_field_call_pattern='tool_field "\$[A-Za-z_][A-Za-z0-9_]*"'
bash_field_extract_pattern='tool_field "\$[A-Za-z_][A-Za-z0-9_]*" [A-Za-z_][A-Za-z0-9_]*'
ps_field_call_pattern='Get-ToolField -Id \$[A-Za-z_][A-Za-z0-9_]*'
ps_field_extract_pattern="-Column '[A-Za-z_][A-Za-z0-9_]*'"

bash_fields=$(grep -oE -- "$bash_field_extract_pattern" "$TOOLS_SH" | awk '{print $NF}' | sort -u)
ps_fields=$(grep -oE -- "$ps_field_extract_pattern" "$TOOLS_PS1" \
  | sed -E "s/-Column '([A-Za-z_][A-Za-z0-9_]*)'/\1/" | sort -u)

if [ -n "$bash_fields" ]; then _bf_state=nonempty; else _bf_state=empty; fi
assert_equals "$_bf_state" "nonempty" \
  "[all] precondition: tools.sh field-name extraction found at least one tool_field reference"
if [ -n "$ps_fields" ]; then _pf_state=nonempty; else _pf_state=empty; fi
assert_equals "$_pf_state" "nonempty" \
  "[all] precondition: Tools.ps1 field-name extraction found at least one Get-ToolField reference"

assert_equals "$bash_fields" "$ps_fields" \
  "[all] static: tools.sh and Tools.ps1 reference the exact same set of tool_field/Get-ToolField column names"

# --- Finding 4 (fix round 1): the extraction regexes above only
# recognize a bareword (tools.sh) or single-quoted-literal (Tools.ps1)
# second argument. A future call site written as tool_field "$id"
# 'purpose', -Column "purpose", or -Column $col is invisible to them —
# and if it happens on BOTH sides at once, the two (silently
# under-collected) sets still match, so the check above passes while
# proving nothing about the unmatched call. Guard against that by
# counting call SITES independently (a looser pattern that recognizes
# the call regardless of how its second argument is written) and
# asserting it equals the number of names actually extracted; a
# mismatch means some call form is going uncounted. ---
bash_call_site_count=$(grep -oE -- "$bash_field_call_pattern" "$TOOLS_SH" | wc -l | tr -d ' ')
bash_extract_count=$(grep -oE -- "$bash_field_extract_pattern" "$TOOLS_SH" | wc -l | tr -d ' ')
assert_equals "$bash_extract_count" "$bash_call_site_count" \
  "[all] static: every tool_field call site in tools.sh yields an extractable bareword column name (no call form is silently uncounted)"

ps_call_site_count=$(grep -oE -- "$ps_field_call_pattern" "$TOOLS_PS1" | wc -l | tr -d ' ')
ps_extract_count=$(grep -oE -- "$ps_field_extract_pattern" "$TOOLS_PS1" | wc -l | tr -d ' ')
assert_equals "$ps_extract_count" "$ps_call_site_count" \
  "[all] static: every Get-ToolField call site in Tools.ps1 yields an extractable single-quoted column name (no call form is silently uncounted)"

# =====================================================================
# Group 6 — static: tools.psv's header matches the union of fields
# referenced by tool_field/Get-ToolField calls ANYWHERE in the plugin —
# not just inside the two reader files.
#
# Fix round 1, Finding 2: scanning only tools.sh/Tools.ps1 (as this group
# originally did) meant a column consumed exclusively by a downstream
# consumer script that sources the readers — e.g. check-deps.sh's
# `tool_field vineflower purpose` — never registered as "used" at all, so
# RESERVED_FUTURE_CONSUMER/DOC_ONLY_COLUMNS could never be forced to
# shrink once consumption moved out of the readers themselves, which is
# exactly what Task 3 onward does. This group now scans every *.sh and
# *.ps1 file under scripts/ (the two readers plus every consumer) with a
# looser bash extraction pattern that accepts any id-argument form (a
# bareword literal, $var, or "$var") — the PowerShell extraction pattern
# already never cared about the -Id argument's form, only -Column's.
#
# Design note: tools.psv (Task 1) deliberately carries columns neither
# resolution reader touches directly yet. Two different reasons, tracked
# separately (fix round 1, Finding 5; widened in fix round 1 on Task 3,
# Finding 2):
#
#   - RESERVED_FUTURE_CONSUMER: platform is reserved for a later 2.0.0
#     task (design doc §7). gh_repo, asset and pin were struck from this
#     list when install-dep.sh's jadx/vineflower installers migrated onto
#     tools.psv; pin_digest was struck in the digest-verification task
#     that made it a real tool_field/Get-ToolField consumer in
#     install-dep.sh/.ps1. Each remaining column is expected to gain a
#     real consumer (in a reader OR any consumer script) in a later task,
#     and MUST be struck from this list in that same change — otherwise
#     it silently joins `used` while staying `reserved`, the allowlist
#     union never shrinks, and nothing ever prompts anyone to edit it.
#     The assertion below enforces that: it fails the moment any
#     reserved-future column shows up in `used`, forcing the list to
#     shrink as tasks land.
#
#   - DOC_ONLY_COLUMNS: columns meant purely for a human reading
#     tools.psv, with no resolution-logic reader. The identical
#     shrink-as-consumed rule now applies here too (fix round 1, Finding
#     2) — a documentation-only column that acquires a real consumer must
#     be struck from this list in the same change. DOC_ONLY_COLUMNS is
#     empty as of this change: `purpose` was its only member, and is now
#     consumed by check-deps.sh/.ps1 (via tool_field/Get-ToolField) to
#     build the "why it's missing" text for optional tools.
# =====================================================================
SCRIPTS_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"

consumer_sh_files=()
while IFS= read -r _consumer_f; do
  consumer_sh_files[${#consumer_sh_files[@]}]="$_consumer_f"
done < <(find "$SCRIPTS_DIR" -name '*.sh' | sort)

consumer_ps1_files=()
while IFS= read -r _consumer_f; do
  consumer_ps1_files[${#consumer_ps1_files[@]}]="$_consumer_f"
done < <(find "$SCRIPTS_DIR" -name '*.ps1' | sort)

if [ "${#consumer_sh_files[@]}" -gt 0 ]; then _csh_state=nonempty; else _csh_state=empty; fi
assert_equals "$_csh_state" "nonempty" \
  "[all] precondition: found at least one *.sh file under scripts/ to scan for tool_field consumers"
if [ "${#consumer_ps1_files[@]}" -gt 0 ]; then _cps_state=nonempty; else _cps_state=empty; fi
assert_equals "$_cps_state" "nonempty" \
  "[all] precondition: found at least one *.ps1 file under scripts/ to scan for Get-ToolField consumers"

bash_wide_field_extract_pattern='tool_field [^[:space:]]+ [A-Za-z_][A-Za-z0-9_]*'
bash_all_fields=$(grep -ohE -- "$bash_wide_field_extract_pattern" \
  ${consumer_sh_files[@]+"${consumer_sh_files[@]}"} 2>/dev/null | awk '{print $NF}' | sort -u)
ps_all_fields=$(grep -ohE -- "$ps_field_extract_pattern" \
  ${consumer_ps1_files[@]+"${consumer_ps1_files[@]}"} 2>/dev/null \
  | sed -E "s/-Column '([A-Za-z_][A-Za-z0-9_]*)'/\1/" | sort -u)

if [ -n "$bash_all_fields" ]; then _baf_state=nonempty; else _baf_state=empty; fi
assert_equals "$_baf_state" "nonempty" \
  "[all] precondition: the widened bash tool_field scan across scripts/ found at least one column reference"
if [ -n "$ps_all_fields" ]; then _paf_state=nonempty; else _paf_state=empty; fi
assert_equals "$_paf_state" "nonempty" \
  "[all] precondition: the widened Get-ToolField scan across scripts/ found at least one column reference"

# Fix round 1, Finding 2, concrete demonstration: the widened scan must
# actually see a consumer-script-only reference. check-deps.sh/.ps1 are
# the only callers of `purpose` anywhere in the plugin (neither reader
# calls tool_field/Get-ToolField with 'purpose' itself), so this fails
# unless the scan genuinely reaches beyond tools.sh/Tools.ps1.
assert_contains "$bash_all_fields" "purpose" \
  "[all] static: the widened scan sees check-deps.sh's tool_field <id> purpose call — a consumer-script-only reference, invisible to a readers-only scan"
assert_contains "$ps_all_fields" "purpose" \
  "[all] static: the widened scan sees check-deps.ps1's Get-ToolField -Column 'purpose' call — a consumer-script-only reference, invisible to a readers-only scan"

header_line=$(head -1 "$TOOLS_PSV")
header_fields=$(printf '%s' "$header_line" | tr '|' '\n' | grep -vFx 'id' | sort -u)
used_fields=$(printf '%s\n%s\n' "$bash_all_fields" "$ps_all_fields" | sort -u)

RESERVED_FUTURE_CONSUMER="platform"
DOC_ONLY_COLUMNS=""
reserved_future_sorted=$(printf '%s\n' $RESERVED_FUTURE_CONSUMER | sort -u)
doc_only_sorted=$(printf '%s\n' $DOC_ONLY_COLUMNS | sort -u)

missing_from_header=$(comm -23 <(printf '%s\n' "$used_fields") <(printf '%s\n' "$header_fields"))
assert_equals "$missing_from_header" "" \
  "[all] static: tools.psv header contains every field name referenced by tool_field/Get-ToolField, in a reader or any consumer script"

allowed_fields=$(printf '%s\n%s\n%s\n' "$used_fields" "$reserved_future_sorted" "$doc_only_sorted" | sort -u)
extra_in_header=$(comm -23 <(printf '%s\n' "$header_fields") <(printf '%s\n' "$allowed_fields"))
assert_equals "$extra_in_header" "" \
  "[all] static: every tools.psv header column is either used by a reader/consumer, reserved for a future consumer, or documentation-only"

# The enforcing half of Finding 5: a reserved-future column that has
# acquired a real consumer — in a reader OR any consumer script — must be
# struck from RESERVED_FUTURE_CONSUMER in the same change. If it isn't,
# it shows up in both `used` and `reserved` at once — this intersection
# must be empty.
reserved_now_used=$(comm -12 <(printf '%s\n' "$used_fields") <(printf '%s\n' "$reserved_future_sorted"))
assert_equals "$reserved_now_used" "" \
  "[all] static: no reserved-for-future-consumer column has acquired a consumer yet, in a reader or any consumer script (strike it from RESERVED_FUTURE_CONSUMER in the same change that adds its first tool_field/Get-ToolField call)"

# Fix round 1, Finding 2 — the symmetric rule for DOC_ONLY_COLUMNS: a
# documentation-only column that has acquired a real consumer must be
# struck from this list in the same change, for the identical reason the
# RESERVED_FUTURE_CONSUMER assertion above exists. This is what lets
# `purpose` acquiring check-deps.sh/.ps1 as a real consumer force
# DOC_ONLY_COLUMNS to actually shrink instead of silently going stale.
doc_only_now_used=$(comm -12 <(printf '%s\n' "$used_fields") <(printf '%s\n' "$doc_only_sorted"))
assert_equals "$doc_only_now_used" "" \
  "[all] static: no documentation-only column has acquired a consumer yet, in a reader or any consumer script (strike it from DOC_ONLY_COLUMNS in the same change that adds its first tool_field/Get-ToolField call)"

# =====================================================================
# Group 8 — fix round 1, Finding 1: the REAL tools.psv jadx row must
# resolve every one of its candidates, including the three Windows-only
# .bat locations restored in this fix round. They were present in the
# pre-resolution-layer check-deps.ps1 (%USERPROFILE%\.local\share\jadx\
# bin\jadx.bat, %USERPROFILE%\jadx\bin\jadx.bat,
# %LOCALAPPDATA%\jadx\bin\jadx.bat) and had been silently dropped when
# tools.psv was authored in Task 1/2 — exactly the "candidate present in
# one file, absent from another" bug class this release exists to
# eliminate. Verified against the REAL tools.psv (not a private fixture)
# so a future edit that narrows the candidates list again is caught here,
# not only in a fixture that could quietly drift out of sync with the
# real data.
# =====================================================================
real_jadx_candidates=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_field jadx candidates')

if [ -n "$real_jadx_candidates" ]; then _rjc_state=nonempty; else _rjc_state=empty; fi
assert_equals "$_rjc_state" "nonempty" \
  "[all] precondition: real tools.psv jadx row has a non-empty candidates field before splitting it"

jadx_cand_list=()
_jc_oldifs="$IFS"
IFS=';'
for _jc in $real_jadx_candidates; do
  IFS="$_jc_oldifs"
  jadx_cand_list[${#jadx_cand_list[@]}]="$_jc"
  IFS=';'
done
IFS="$_jc_oldifs"

expected_jadx_candidate_count=4
assert_equals "${#jadx_cand_list[@]}" "$expected_jadx_candidate_count" \
  "[all] precondition: real tools.psv jadx row lists exactly the expected 4 candidates (1 Unix + 3 restored Windows .bat locations) before testing each individually"

_jc_idx=0
while [ "$_jc_idx" -lt "${#jadx_cand_list[@]}" ]; do
  _jc_template="${jadx_cand_list[$_jc_idx]}"
  jhome=$(new_tmpdir)
  jlocalappdata=$(new_tmpdir)
  jbin=$(new_tmpdir)
  _jc_expected=$(printf '%s' "$_jc_template" | sed "s#{HOME}#$jhome#g; s#{LOCALAPPDATA}#$jlocalappdata#g")
  mkdir -p "$(dirname "$_jc_expected")"
  touch "$_jc_expected"

  # PATH is a fresh, empty tmpdir with nothing else appended: no real
  # "jadx" can be found on it, so resolution is forced past the PATH
  # probe and down to exactly this one candidate (nothing earlier in the
  # list is created in this fixture, so an earlier one winning by
  # accident would be a false pass, not a coincidence to worry about).
  _jc_out=$(HOME="$jhome" LOCALAPPDATA="$jlocalappdata" PATH="$jbin" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" TOOLS_SH_PATH="$TOOLS_SH" \
    "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_resolve jadx')
  assert_equals "$_jc_out" "$_jc_expected" \
    "[all] tool_resolve: real jadx candidate #$((_jc_idx + 1)) ($_jc_template) is found by itself, with no earlier candidate present and nothing on PATH"
  _jc_idx=$((_jc_idx + 1))
done

# =====================================================================
# Group 11 (2.0.0 fix wave, I2) — a tools.psv saved with CRLF line endings
# must not silently break tools.sh's last-column lookups. `IFS= read -r
# header` keeps a trailing \r on the line it reads, so before this fix the
# header's last field was "purpose\r", which never equals the bareword
# "purpose" a caller asks for - every last-column lookup failed outright,
# even though the row's data itself was perfectly readable. Only
# .gitattributes normalization prevented this in practice; neither reader
# guarded against it directly before this fix. Tools.ps1's regex-based
# line splitter ([regex]::Split($raw, "\r\n|\n")) was never affected -
# this is a bash-only defect.
# =====================================================================
crlf_root=$(new_tmpdir)
crlf_lib="$crlf_root/skills/android-reverse-engineering/scripts/lib"
mkdir -p "$crlf_lib"
printf 'id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose\r\nwidget|required|all|path|-|-|-|-|-|-|-|Widget purpose text\r\n' \
  > "$crlf_lib/tools.psv"

crlf_purpose=$(CLAUDE_PLUGIN_ROOT="$crlf_root" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_field widget purpose')
crlf_status=$?

assert_equals "$crlf_status" "0" \
  "[all] tools.sh: tool_field succeeds on a CRLF-saved tools.psv's last column, instead of failing outright"
assert_equals "$crlf_purpose" "Widget purpose text" \
  "[all] tools.sh: tool_field strips the trailing \\r from a CRLF-saved tools.psv's last column and returns the real value"

# The assertion above alone is not a reliable guard for the per-ROW \r
# strip specifically (as opposed to the header \r strip): some shells'
# `$(...)` command substitution runs through a pipe that can itself
# normalize a trailing "\r\n" to "\n" in transit (observed on MSYS/Git-Bash
# on Windows), which would make this assertion pass even with the row-level
# strip removed, silently masking that specific regression. Redirecting to
# a real file instead of capturing through a pipe/command-substitution
# sidesteps that normalization and checks the actual bytes tool_field wrote
# — the same property, checked in a way that cannot be quietly
# short-circuited by a pipe's own text-mode translation.
crlf_out_dir=$(new_tmpdir)
CLAUDE_PLUGIN_ROOT="$crlf_root" TOOLS_SH_PATH="$TOOLS_SH" "${BASH:-bash}" -c \
  '. "$TOOLS_SH_PATH"; tool_field widget purpose' > "$crlf_out_dir/purpose.out"
crlf_out_bytes=$(wc -c < "$crlf_out_dir/purpose.out" | tr -d ' ')
# Expected: "Widget purpose text" (19 bytes) + a single trailing "\n" (1
# byte, from tool_field's own `printf '%s\n'`) = 20 bytes total, with no
# embedded \r. If the row-level strip were removed, the file would instead
# hold 21 bytes ("...text" + "\r" + "\n").
assert_equals "$crlf_out_bytes" "20" \
  "[all] tools.sh: tool_field's raw output bytes (checked via file redirection, not a pipe) contain no embedded \\r from a CRLF-saved row"

# =====================================================================
# Group 7 — PowerShell runtime consistency: the same fixture fed to both
# readers, compared verbatim (no trim/case-fold/sort — §6.2 shape 4).
# Only runs where pwsh or powershell exists; SKIP is visibly distinct
# from a passing assertion (§6.2 shape 3).
#
# The fixture below also covers (fix round 1):
#   - Finding 2: `rtrail`'s last column (purpose) is genuinely empty, to
#     verify Tools.ps1's trailing-empty-field handling now matches
#     tools.sh's (both must report the column as absent, not present-and-
#     empty).
#   - Finding 7: a comment row and a blank row, matching the bash-only
#     fixture above — Get-ToolList's own comment/blank-skipping logic had
#     no test before this.
#   - Finding 8: `rhome` uses a real {HOME} placeholder (rather than a
#     pre-expanded literal path like the other rows), with HOME and
#     USERPROFILE both pointed at the same native directory for their
#     respective child processes, to prove both readers' {HOME}
#     expansion resolves to the SAME file on disk. This does not (and
#     structurally cannot) compare the two interpreters' *default*
#     home-directory derivation as raw strings — $HOME and
#     $env:USERPROFILE naturally differ in representation even on one
#     Git-Bash-on-Windows machine (e.g. /c/Users/foo vs C:\Users\foo) —
#     see the comment on Expand-ToolPlaceholders in Tools.ps1 and on
#     _tools_expand in tools.sh for why that omission is deliberate.
#   - Fix round 1, Finding 1: `rlocalappdata` covers the new {LOCALAPPDATA}
#     placeholder the same way `rhome` covers {HOME} — both readers'
#     LOCALAPPDATA-equivalent variable is pointed at the same native
#     directory as HOME/USERPROFILE, and both must expand {LOCALAPPDATA}
#     to a path resolving to the SAME file on disk.
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
# comment row: must be skipped by both readers

rone|required|all|path|-|RONE_ENV|$native_home/rone-candidate|-|-|-|-|Cross-reader env-priority test
rtwo|optional|all|jar|-|-|$native_home/rtwo-candidate.jar|-|-|-|-|Cross-reader candidate-only jar test
rthree|required|all|path|-|RTHREE_ENV|$native_home/rthree-candidate|-|-|-|-|Cross-reader env-invalid-falls-through test
rfour|optional|all|path|-|-|$native_home/rfour-candidate-MISSING|-|-|-|-|Cross-reader tool-missing test
rhome|required|all|path|-|-|{HOME}/rhome-candidate|-|-|-|-|Cross-reader HOME-expansion test
rlocalappdata|required|all|path|-|-|{LOCALAPPDATA}/rlocalappdata-candidate|-|-|-|-|Cross-reader LOCALAPPDATA-expansion test
rtrail|required|all|path|-|-|-|-|-|-|-|
PSV

  touch "$cross_home/rone-env-target" "$cross_home/rone-candidate" \
        "$cross_home/rtwo-candidate.jar" "$cross_home/rthree-candidate" \
        "$cross_home/rhome-candidate" "$cross_home/rlocalappdata-candidate"
  # rfour-candidate-MISSING deliberately not created.

  rone_env_native="$native_home/rone-env-target"
  rthree_env_missing_native="$native_home/rthree-env-target-MISSING"
  rhome_candidate_native="$native_home/rhome-candidate"
  rlocalappdata_candidate_native="$native_home/rlocalappdata-candidate"
  native_cross_root=$(to_native_path "$cross_root")
  native_tools_ps1=$(to_native_path "$TOOLS_PS1")

  bash_cross_out=$(CLAUDE_PLUGIN_ROOT="$cross_root" TOOLS_SH_PATH="$TOOLS_SH" \
    HOME="$native_home" LOCALAPPDATA="$native_home" \
    RONE_ENV="$rone_env_native" RTHREE_ENV="$rthree_env_missing_native" \
    "${BASH:-bash}" -c '
      . "$TOOLS_SH_PATH"
      printf "LIST=%s\n" "$(tool_list | tr "\n" ",")"
      for id in rone rtwo rthree rfour rhome rlocalappdata rtrail; do
        for col in kind env_override candidates required purpose; do
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
foreach ($id in @('rone', 'rtwo', 'rthree', 'rfour', 'rhome', 'rlocalappdata', 'rtrail')) {
    foreach ($col in @('kind', 'env_override', 'candidates', 'required', 'purpose')) {
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
    USERPROFILE="$native_home" LOCALAPPDATA="$native_home" \
    RONE_ENV="$rone_env_native" RTHREE_ENV="$rthree_env_missing_native" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$ps_script" 2>&1 | tr -d '\r')

  # --- preconditions (§6.2 shapes 1 & 2), asserted BEFORE the full-output
  # comparison, each against a specific known-non-empty expected value ---
  assert_contains "$bash_cross_out" "LIST=rone,rtwo,rthree,rfour,rhome,rlocalappdata,rtrail," \
    "[win] precondition: tools.sh loaded the cross-reader fixture (tool_list returns the expected 7 ids, skipping the comment/blank rows)"
  assert_contains "$ps_cross_out" "LIST=rone,rtwo,rthree,rfour,rhome,rlocalappdata,rtrail," \
    "[win] precondition: Tools.ps1 loaded the cross-reader fixture (Get-ToolList returns the expected 7 ids, skipping the comment/blank rows)"
  assert_contains "$bash_cross_out" "RESOLVE=rone|$rone_env_native" \
    "[win] precondition: tools.sh resolves rone via env override to the expected non-empty path"
  assert_contains "$ps_cross_out" "RESOLVE=rone|$rone_env_native" \
    "[win] precondition: Tools.ps1 resolves rone via env override to the expected non-empty path"
  assert_contains "$bash_cross_out" "RESOLVE=rfour|<NULL>" \
    "[win] precondition: tools.sh reports rfour (no env, no probe, missing candidate) as unresolved, not a false match"
  assert_contains "$ps_cross_out" "RESOLVE=rfour|<NULL>" \
    "[win] precondition: Tools.ps1 reports rfour (no env, no probe, missing candidate) as unresolved, not a false match"

  # --- Finding 2: a trailing-empty last column must be reported as
  # absent (not present-and-empty) by both readers ---
  assert_contains "$bash_cross_out" "FIELD=rtrail|purpose|<NULL>" \
    "[win] precondition: tools.sh reports a trailing-empty final column as absent, not present-and-empty"
  assert_contains "$ps_cross_out" "FIELD=rtrail|purpose|<NULL>" \
    "[win] precondition: Tools.ps1 reports a trailing-empty final column as absent, not present-and-empty (fix round 1, Finding 2)"

  # --- Finding 8: both readers expand {HOME} to a path resolving to the
  # same file on disk, when pointed at the same native directory ---
  assert_contains "$bash_cross_out" "RESOLVE=rhome|$rhome_candidate_native" \
    "[win] precondition: tools.sh expands {HOME} in a candidate path to the expected non-empty resolved path"
  assert_contains "$ps_cross_out" "RESOLVE=rhome|$rhome_candidate_native" \
    "[win] Tools.ps1 expands {HOME} to the same resolved file tools.sh does, when both point at the same native directory"

  # --- Fix round 1, Finding 1: both readers expand {LOCALAPPDATA} to a
  # path resolving to the same file on disk, when pointed at the same
  # native directory ---
  assert_contains "$bash_cross_out" "RESOLVE=rlocalappdata|$rlocalappdata_candidate_native" \
    "[win] precondition: tools.sh expands {LOCALAPPDATA} in a candidate path to the expected non-empty resolved path (fix round 1, Finding 1)"
  assert_contains "$ps_cross_out" "RESOLVE=rlocalappdata|$rlocalappdata_candidate_native" \
    "[win] Tools.ps1 expands {LOCALAPPDATA} to the same resolved file tools.sh does, when both point at the same native directory (fix round 1, Finding 1)"

  # --- the actual cross-reader comparison: verbatim, no normalization ---
  assert_equals "$bash_cross_out" "$ps_cross_out" \
    "[win] runtime cross-reader consistency: tool_list/tool_field/tool_resolve output from tools.sh exactly matches Get-ToolList/Get-ToolField/Resolve-Tool output from Tools.ps1 on the same fixture"

  # =====================================================================
  # Group 7b (fix round 1, Finding 6) — Tools.ps1's OWN resolution order:
  # env override must win over a PATH probe match. Group 7 above sets
  # probe='-' on every row to sidestep a structural limitation
  # (make_stub_bin's extensionless stub is invisible to PowerShell's
  # Get-Command -CommandType Application on Windows, which only
  # recognizes PATHEXT extensions), so nothing above exercises this
  # order in Tools.ps1 at all — and until now, no mutation targeting
  # Tools.ps1 existed either. A real .cmd stub IS visible to Get-Command
  # Application, closing both gaps: this assertion is the [win]
  # counterpart to bash Group 3 Case 1, and it is what
  # psv-ps-reader-order.mutation's EXPECT: targets.
  # =====================================================================
  porder_root=$(new_tmpdir)
  porder_lib="$porder_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$porder_lib"
  porder_home=$(new_tmpdir)
  native_porder_home=$(to_native_path "$porder_home")
  touch "$porder_home/porder-env-target"

  cat > "$porder_lib/tools.psv" <<PSV
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
porder|required|all|path|porder-cli-stub-zzz|PORDER_ENV|$native_porder_home/porder-candidate|-|-|-|-|PowerShell-only env-vs-probe order test
PSV

  porder_bin=$(new_tmpdir)
  native_porder_bin=$(to_native_path "$porder_bin")
  cat > "$porder_bin/porder-cli-stub-zzz.cmd" <<'CMD'
@echo off
exit /b 0
CMD

  native_porder_root=$(to_native_path "$porder_root")
  porder_env_native="$native_porder_home/porder-env-target"

  porder_script_dir=$(new_tmpdir)
  porder_script="$porder_script_dir/porder-check.ps1"
  cat > "$porder_script" <<'EOF'
$ErrorActionPreference = 'Stop'
# Set $env:PATH from a differently-named variable, inside the script,
# rather than passing PATH="$native_porder_bin" from bash: Git-Bash/MSYS
# auto-converts the PATH env var specially, and a native Windows path
# with a drive-letter colon (C:\...) gets its colon misread as a POSIX
# PATH-list separator in that conversion, corrupting the value before
# pwsh.exe ever sees it. STUB_BIN_DIR is not a recognized/converted name,
# so it arrives intact and this script sets $env:PATH itself.
$env:PATH = $env:STUB_BIN_DIR
. $env:TOOLS_PS1_PATH
$r = Resolve-Tool -Id 'porder'
if ($null -eq $r) { Write-Output 'RESOLVE=<NULL>' } else { Write-Output ('RESOLVE=' + $r.Path) }
EOF

  porder_out=$(CLAUDE_PLUGIN_ROOT="$native_porder_root" TOOLS_PS1_PATH="$native_tools_ps1" \
    PORDER_ENV="$porder_env_native" STUB_BIN_DIR="$native_porder_bin" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$porder_script" 2>&1 | tr -d '\r')

  assert_contains "$porder_out" "RESOLVE=$porder_env_native" \
    "[win] Tools.ps1 resolution order: env override wins over PATH probe when both are present"

  # =====================================================================
  # Group 7c (Task 4 review C1/I2) — Resolve-Tool must report Kind='cli'
  # when a jar-kind tool (per tools.psv) is actually found via the PATH
  # probe as a real executable, not the raw .jar candidate. Before the
  # fix, Resolve-Tool derived Kind purely from the static tools.psv kind
  # column, so a probe match on a jar-kind id still came back Kind='jar' -
  # and decompile.ps1 wrapped that CLI's path in `java -jar <script>`,
  # which fails immediately (announcing failure while printing a success
  # banner, per the C1 finding). This is the PowerShell reader-level
  # counterpart to Group 4's bash tool_argv probe-vs-jar assertion above;
  # until this group existed, reverting Tools.ps1's `Kind = 'cli'` back to
  # `Kind = $kind` left every reader-level test green — only a bash-only
  # decompile.sh test caught the bug at all, and nothing caught it on the
  # platform it actually broke.
  # =====================================================================
  pcli_root=$(new_tmpdir)
  pcli_lib="$pcli_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$pcli_lib"
  pcli_home=$(new_tmpdir)
  native_pcli_home=$(to_native_path "$pcli_home")
  touch "$pcli_home/pcli-candidate.jar"

  cat > "$pcli_lib/tools.psv" <<PSV
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
pclitool|optional|all|jar|pcli-cli-stub-zzz|-|$native_pcli_home/pcli-candidate.jar|-|-|-|-|PowerShell-only probe-kind test
PSV

  pcli_bin=$(new_tmpdir)
  native_pcli_bin=$(to_native_path "$pcli_bin")
  cat > "$pcli_bin/pcli-cli-stub-zzz.cmd" <<'CMD'
@echo off
exit /b 0
CMD

  native_pcli_root=$(to_native_path "$pcli_root")

  pcli_script_dir=$(new_tmpdir)
  pcli_script="$pcli_script_dir/pcli-check.ps1"
  cat > "$pcli_script" <<'EOF'
$ErrorActionPreference = 'Stop'
$env:PATH = $env:STUB_BIN_DIR
. $env:TOOLS_PS1_PATH
$r = Resolve-Tool -Id 'pclitool'
if ($null -eq $r) {
    Write-Output 'RESOLVE=<NULL>'
} else {
    Write-Output ('RESOLVE_KIND=' + $r.Kind)
    Write-Output ('RESOLVE_PATH=' + $r.Path)
}
EOF

  pcli_out=$(CLAUDE_PLUGIN_ROOT="$native_pcli_root" TOOLS_PS1_PATH="$native_tools_ps1" \
    STUB_BIN_DIR="$native_pcli_bin" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$pcli_script" 2>&1 | tr -d '\r')

  assert_contains "$pcli_out" "RESOLVE_KIND=cli" \
    "[win] Resolve-Tool reports Kind=cli when a jar-kind tool is actually found via the PATH probe (not wrapped in java -jar)"
  assert_contains "$pcli_out" "pcli-cli-stub-zzz.cmd" \
    "[win] Resolve-Tool's probe-matched Path names the CLI found on PATH, not the jar candidate"

  # =====================================================================
  # Group 9 (2.0.0 fix wave, C1) — Get-ToolArgv is Tools.ps1's counterpart
  # to tools.sh's tool_argv, added because decompile.ps1 had nowhere to
  # get a resolved java from and was calling the bare `java` command
  # directly (ignoring JAVA_BIN and every tools.psv candidate). This is
  # the [win] counterpart to Group 4's bash tool_argv assertions above:
  # kind=path is a one-element argv; kind=jar is (java, '-jar', <jar
  # path>) with java resolved through Resolve-Tool -Id 'java', not a
  # hard-coded 'java' literal; a jar-kind tool actually found via the PATH
  # probe produces a one-element argv (direct exec, not java -jar).
  # =====================================================================
  g9_root=$(new_tmpdir)
  g9_lib="$g9_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$g9_lib"
  g9_home=$(new_tmpdir)
  native_g9_home=$(to_native_path "$g9_home")
  touch "$g9_home/g9-widget-candidate" "$g9_home/g9-java-candidate" \
        "$g9_home/g9-gadget-candidate.jar" "$g9_home/g9-gadgetcli-candidate.jar"

  cat > "$g9_lib/tools.psv" <<PSV
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
g9widget|required|all|path|-|-|$native_g9_home/g9-widget-candidate|-|-|-|-|Get-ToolArgv path-kind test
java|required|all|path|-|-|$native_g9_home/g9-java-candidate|-|-|-|-|Get-ToolArgv java-resolution test
g9gadget|optional|all|jar|-|-|$native_g9_home/g9-gadget-candidate.jar|-|-|-|-|Get-ToolArgv jar-kind test
g9gadgetcli|optional|all|jar|g9-gadgetcli-stub-zzz|-|$native_g9_home/g9-gadgetcli-candidate.jar|-|-|-|-|Get-ToolArgv probe-matched-jar test
PSV

  g9_bin=$(new_tmpdir)
  native_g9_bin=$(to_native_path "$g9_bin")
  cat > "$g9_bin/g9-gadgetcli-stub-zzz.cmd" <<'CMD'
@echo off
exit /b 0
CMD

  native_g9_root=$(to_native_path "$g9_root")

  g9_script_dir=$(new_tmpdir)
  g9_script="$g9_script_dir/g9-check.ps1"
  cat > "$g9_script" <<'EOF'
$ErrorActionPreference = 'Stop'
$env:PATH = $env:STUB_BIN_DIR
. $env:TOOLS_PS1_PATH
$w = Get-ToolArgv -Id 'g9widget'
Write-Output ('WIDGET_COUNT=' + $w.Count)
Write-Output ('WIDGET_0=' + $w[0])

$g = Get-ToolArgv -Id 'g9gadget'
Write-Output ('GADGET_COUNT=' + $g.Count)
Write-Output ('GADGET_0=' + $g[0])
Write-Output ('GADGET_1=' + $g[1])
Write-Output ('GADGET_2=' + $g[2])

$c = Get-ToolArgv -Id 'g9gadgetcli'
Write-Output ('GADGETCLI_COUNT=' + $c.Count)
Write-Output ('GADGETCLI_0=' + $c[0])
EOF

  g9_out=$(CLAUDE_PLUGIN_ROOT="$native_g9_root" TOOLS_PS1_PATH="$native_tools_ps1" \
    STUB_BIN_DIR="$native_g9_bin" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$g9_script" 2>&1 | tr -d '\r')

  assert_contains "$g9_out" "WIDGET_COUNT=1" \
    "[win] Get-ToolArgv: kind=path produces a single-element argv"
  assert_contains "$g9_out" "WIDGET_0=$native_g9_home/g9-widget-candidate" \
    "[win] Get-ToolArgv: kind=path's single element is the resolved tool path"

  assert_contains "$g9_out" "GADGET_COUNT=3" \
    "[win] Get-ToolArgv: kind=jar produces a three-element argv (java, -jar, <path>)"
  assert_contains "$g9_out" "GADGET_0=$native_g9_home/g9-java-candidate" \
    "[win] Get-ToolArgv: kind=jar's java element comes from Resolve-Tool -Id 'java', not a hard-coded 'java' literal"
  assert_contains "$g9_out" "GADGET_1=-jar" \
    "[win] Get-ToolArgv: kind=jar's second element is the literal -jar flag"
  assert_contains "$g9_out" "GADGET_2=$native_g9_home/g9-gadget-candidate.jar" \
    "[win] Get-ToolArgv: kind=jar's third element is the resolved jar path"

  assert_contains "$g9_out" "GADGETCLI_COUNT=1" \
    "[win] Get-ToolArgv: kind=jar found via PATH probe produces a single-element argv (direct exec, not java -jar)"
  assert_contains "$g9_out" "g9-gadgetcli-stub-zzz.cmd" \
    "[win] Get-ToolArgv: kind=jar's probe-matched element is the CLI found on PATH, not the jar candidate"

  # =====================================================================
  # Group 10 (2.0.0 fix wave, I1) — an empty element in a candidates list
  # (e.g. a stray ";;") must be skipped, not thrown on. Reproduced against
  # the pre-fix Tools.ps1: Expand-ToolPlaceholders declared its $Value
  # parameter as [Parameter(Mandatory=$true)][string] with no
  # AllowEmptyString, which PowerShell rejects outright for an empty-string
  # argument ("Cannot bind argument to parameter 'Value' because it is an
  # empty string.") - a terminating parameter-binding error regardless of
  # $ErrorActionPreference, aborting the whole calling script before
  # Resolve-Tool could ever reach a later candidate (here, a second
  # nonexistent one) that tools.sh's equivalent loop would harmlessly skip
  # past (`[ -f "" ]` is simply false, not fatal).
  # =====================================================================
  g10_root=$(new_tmpdir)
  g10_lib="$g10_root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$g10_lib"
  cat > "$g10_lib/tools.psv" <<'PSV'
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
g10widget|required|all|path|-|-|/nonexistent/g10-a;;/nonexistent/g10-b|-|-|-|-|empty-candidate-element test
PSV
  native_g10_root=$(to_native_path "$g10_root")

  g10_script_dir=$(new_tmpdir)
  g10_script="$g10_script_dir/g10-check.ps1"
  cat > "$g10_script" <<'EOF'
$ErrorActionPreference = 'Stop'
. $env:TOOLS_PS1_PATH
try {
    $r = Resolve-Tool -Id 'g10widget'
    if ($null -eq $r) { Write-Output 'RESOLVE=<NULL>' } else { Write-Output ('RESOLVE=' + $r.Path) }
} catch {
    Write-Output ('THREW=' + $_.Exception.Message)
}
EOF

  g10_out=$(CLAUDE_PLUGIN_ROOT="$native_g10_root" TOOLS_PS1_PATH="$native_tools_ps1" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$g10_script" 2>&1 | tr -d '\r')

  assert_contains "$g10_out" "RESOLVE=<NULL>" \
    "[win] Resolve-Tool skips an empty element in a candidates list (e.g. a stray ';;') instead of throwing, and continues to report the tool unresolved"
  assert_not_contains "$g10_out" "THREW=" \
    "[win] Resolve-Tool does not raise a parameter-binding error on an empty candidates-list element"

  # Direct unit-level guard on Expand-ToolPlaceholders itself, independent
  # of Resolve-Tool's own empty-element skip: even if that skip were ever
  # removed or bypassed, Expand-ToolPlaceholders must still accept an
  # empty string rather than reject it as a missing Mandatory argument.
  g10b_script_dir=$(new_tmpdir)
  g10b_script="$g10b_script_dir/g10b-check.ps1"
  cat > "$g10b_script" <<'EOF'
$ErrorActionPreference = 'Stop'
. $env:TOOLS_PS1_PATH
try {
    $r = Expand-ToolPlaceholders -Value ''
    Write-Output ('EXPANDED=[' + $r + ']')
} catch {
    Write-Output ('THREW=' + $_.Exception.Message)
}
EOF
  g10b_out=$(TOOLS_PS1_PATH="$native_tools_ps1" \
    "$PWSH_BIN" -NoProfile -NonInteractive -File "$g10b_script" 2>&1 | tr -d '\r')

  assert_contains "$g10b_out" "EXPANDED=[]" \
    "[win] Expand-ToolPlaceholders accepts an empty string ([AllowEmptyString()]) instead of rejecting it as a missing Mandatory argument"
fi

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
