#!/usr/bin/env bash
# Static portability guards: the scripts must run on stock macOS
# (/bin/bash 3.2, BSD find/grep/sed). These greps prevent regressions.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"

CASE_MOD_REGEX='\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,{1,2}|\^{1,2})\}'

# scan_hits <dir> <extended-regex> [exclude-basename]
# Prints grep -nE hits for <regex> across *.sh under <dir>, with full-line
# comments filtered out (a line that is nothing but a comment, once leading
# whitespace is stripped, starts with '#'). Known limitation: a trailing
# comment on an otherwise real code line is still matched — that's
# acceptable, since a construct in a trailing comment sits right next to
# real code and is worth a second look anyway.
#
# [exclude-basename], if given, drops hits from that one file. It exists
# for exactly one caller below: scanning tests/*.sh with these same
# patterns would flag this very file's own regex definitions, labels, and
# self-test fixtures (grep can't tell "the string this scanner matches
# against" from "the construct this scanner is banning"). Everything else
# under tests/ is scanned with no exclusion.
scan_hits() {
  local dir="$1" regex="$2" exclude="${3:-}" hits
  hits=$(grep -nHE "$regex" "$dir"/*.sh 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)
  if [ -n "$exclude" ] && [ -n "$hits" ]; then
    hits=$(printf '%s\n' "$hits" | grep -v "/$exclude:" || true)
  fi
  echo "$hits"
}

# scan <label> <extended-regex> [dir] [exclude-basename]
# Fails when any *.sh under [dir] (default: SCRIPT_DIR) matches the regex
# (outside full-line comments).
scan() {
  local label="$1" regex="$2" dir="${3:-$SCRIPT_DIR}" exclude="${4:-}" hits
  hits=$(scan_hits "$dir" "$regex" "$exclude")
  assert_equals "$hits" "" "$label"
}

# --- D5: bash 4+ only constructs ---
scan "no associative arrays (bash 4+)" 'declare -A|local -A'
scan "no case-modification expansion (bash 4+)" "$CASE_MOD_REGEX"
scan "no mapfile/readarray (bash 4+)" '\b(mapfile|readarray)\b'
scan "no namerefs (bash 4.3+)" 'declare -n|local -n'

# --- self-tests: scan_hits()'s comment filter must drop a full-line
# comment mentioning a banned construct, while still catching the same
# construct written as real code ---
sc_comment_dir=$(new_tmpdir)
cat > "$sc_comment_dir/fixture.sh" <<'EOF'
#!/usr/bin/env bash
  # full-line comment mentioning declare -A on purpose; must not be flagged
EOF
sc_comment_hits=$(scan_hits "$sc_comment_dir" 'declare -A|local -A')
assert_equals "$sc_comment_hits" "" \
  "scan_hits() self-test: full-line comment mentioning the construct is filtered out"

sc_code_dir=$(new_tmpdir)
cat > "$sc_code_dir/fixture.sh" <<'EOF'
#!/usr/bin/env bash
declare -A REAL=()
EOF
sc_code_hits=$(scan_hits "$sc_code_dir" 'declare -A|local -A')
assert_contains "$sc_code_hits" "declare -A REAL=()" \
  "scan_hits() self-test: the same construct as real code is still detected"

sc_widen_dir=$(new_tmpdir)
cat > "$sc_widen_dir/fixture.sh" <<'EOF'
#!/usr/bin/env bash
echo "${x,}"
echo "${y^}"
EOF
sc_widen_hits=$(scan_hits "$sc_widen_dir" "$CASE_MOD_REGEX")
assert_contains "$sc_widen_hits" '${x,}' \
  "case-mod regex self-test: catches single-char lowercase fold \${var,}"
assert_contains "$sc_widen_hits" '${y^}' \
  "case-mod regex self-test: catches single-char uppercase fold \${var^}"

# --- D4: GNU-only tool options (absent on BSD/macOS) ---
scan "no find -printf (GNU only)" '\bfind\b[^|]*-printf'
scan "no grep -oP / -P (GNU only)" 'grep[^|]*[[:space:]]-[a-zA-Z]*P\b'
scan "no readlink -f (GNU only)" '\breadlink[[:space:]]+-f\b'

# --- SIGPIPE guard: every script under SCRIPT_DIR sets `set -euo pipefail`.
# `head` exits as soon as it has read the lines it wants, which can send
# SIGPIPE to a still-writing upstream command; pipefail then turns that
# into a script-aborting failure that is load-dependent and intermittent.
# A pipe into `head` in one of these scripts is therefore unsafe by
# construction — require a space between the pipe and `head` so this does
# not fire on a regex literal that merely contains "|head|" as an
# alternation (e.g. '...(get|head|request)...'), which is not a shell pipe.
PIPE_HEAD_REGEX='\|[[:space:]]+head\b'
scan "no pipe into head (SIGPIPE-unsafe under set -o pipefail)" "$PIPE_HEAD_REGEX"

# --- self-tests: the pipe-into-head regex must catch a real shell pipe
# while ignoring "|head|" written as a regex-literal alternation (which
# has no space after the pipe and is not a shell pipe at all) ---
sc_pipehead_dir=$(new_tmpdir)
cat > "$sc_pipehead_dir/fixture.sh" <<'EOF'
#!/usr/bin/env bash
v=$(some_producer | head -1)
EOF
sc_pipehead_hits=$(scan_hits "$sc_pipehead_dir" "$PIPE_HEAD_REGEX")
assert_contains "$sc_pipehead_hits" '| head -1' \
  "pipe-into-head regex self-test: catches a real shell pipe into head"

sc_pipehead_regexliteral_dir=$(new_tmpdir)
cat > "$sc_pipehead_regexliteral_dir/fixture.sh" <<'EOF'
#!/usr/bin/env bash
run_grep '\b(client)\.(get|post|put|delete|patch|head|request)\s*[<(]'
EOF
sc_pipehead_regexliteral_hits=$(scan_hits "$sc_pipehead_regexliteral_dir" "$PIPE_HEAD_REGEX")
assert_equals "$sc_pipehead_regexliteral_hits" "" \
  "pipe-into-head regex self-test: does not flag '|head|' inside a regex literal (no space, not a shell pipe)"

# --- tests-tree guard: the test harness and test files are the only way
# these fixes get verified on stock macOS bash 3.2, so they must run
# there too. Scan tests/ and tests/lib/ with the same patterns.
#
# test-portability.sh (this file) is excluded from the tests/ pass only:
# it is the scanner, so its source necessarily contains these banned
# substrings verbatim — in the regex patterns above, in their
# human-readable labels, and in the self-test fixtures right above this
# comment. Those fixtures already prove, by actually executing
# scan_hits() rather than statically grepping the file that defines it,
# that the comment filter works in both directions. Every other file
# under tests/ and tests/lib/ — including any added later — is scanned
# with no exclusion.
scan "no associative arrays in tests/ (bash 4+)" 'declare -A|local -A' "$REPO_ROOT/tests" test-portability.sh
scan "no case-modification expansion in tests/ (bash 4+)" "$CASE_MOD_REGEX" "$REPO_ROOT/tests" test-portability.sh
scan "no mapfile/readarray in tests/ (bash 4+)" '\b(mapfile|readarray)\b' "$REPO_ROOT/tests" test-portability.sh
scan "no namerefs in tests/ (bash 4.3+)" 'declare -n|local -n' "$REPO_ROOT/tests" test-portability.sh
scan "no find -printf in tests/ (GNU only)" '\bfind\b[^|]*-printf' "$REPO_ROOT/tests" test-portability.sh
scan "no grep -oP / -P in tests/ (GNU only)" 'grep[^|]*[[:space:]]-[a-zA-Z]*P\b' "$REPO_ROOT/tests" test-portability.sh
scan "no readlink -f in tests/ (GNU only)" '\breadlink[[:space:]]+-f\b' "$REPO_ROOT/tests" test-portability.sh

scan "no associative arrays in tests/lib (bash 4+)" 'declare -A|local -A' "$REPO_ROOT/tests/lib"
scan "no case-modification expansion in tests/lib (bash 4+)" "$CASE_MOD_REGEX" "$REPO_ROOT/tests/lib"
scan "no mapfile/readarray in tests/lib (bash 4+)" '\b(mapfile|readarray)\b' "$REPO_ROOT/tests/lib"
scan "no namerefs in tests/lib (bash 4.3+)" 'declare -n|local -n' "$REPO_ROOT/tests/lib"
scan "no find -printf in tests/lib (GNU only)" '\bfind\b[^|]*-printf' "$REPO_ROOT/tests/lib"
scan "no grep -oP / -P in tests/lib (GNU only)" 'grep[^|]*[[:space:]]-[a-zA-Z]*P\b' "$REPO_ROOT/tests/lib"
scan "no readlink -f in tests/lib (GNU only)" '\breadlink[[:space:]]+-f\b' "$REPO_ROOT/tests/lib"

# --- PowerShell guard: every `Get-Command ... -CommandType Application`
# must be wrapped in @().
#
# Get-Command returns EVERY match on PATH. On a Windows box with a real
# Python install alongside the Microsoft Store alias, `Get-Command
# python -CommandType Application` returns two — so an unwrapped
# $cmd.Source is an Object[]. Binding that to a [string] parameter is a
# terminating error under this project's $ErrorActionPreference =
# 'Stop', and it killed check-deps.ps1 outright before it could report
# python3 at all; comparing it with -eq silently becomes an array filter
# instead of the scalar comparison it reads as.
#
# Both are invisible to a fixture that puts one file per name in one
# directory, which is what every PowerShell fixture here did. A static
# scan does not depend on the fixture's shape.
gc_unwrapped=$(grep -nE 'Get-Command [^|]*-CommandType Application' \
  "$SCRIPT_DIR"/*.ps1 "$SCRIPT_DIR"/lib/*.ps1 2>/dev/null \
  | grep -v '@(Get-Command' \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)
assert_equals "$gc_unwrapped" "" \
  "[all] static: every Get-Command -CommandType Application in the PowerShell scripts is wrapped in @() (it returns every PATH match, not one)"

# --- mutation-manifest guard: every .mutation's FIND: line must still
# match exactly one line of the file it names.
#
# run-mutations.sh checks this itself (grep -cFx, ERROR on 0 or on more
# than 1) — but only when it reaches that mutation, minutes into a run
# that executes the entire suite once per mutation. Renaming two locals
# inside tests/lib/harness.sh invalidated a FIND: here, run-tests.sh
# stayed green, and the only thing that noticed was CI's mutation job,
# seven minutes into the run after the push. A stale FIND is not a
# runtime property; it is detectable by reading two files, so it is
# checked here in under a second as well.
#
# grep -cFx, not -cF, to match run-mutations.sh exactly: FIND is a whole
# line, and a substring check here would pass on drift that the real
# runner then rejects.
# stale_mutations <mutations-dir> <root>
# Prints one token per drifted FIND:, empty when every mutation still
# resolves. Taking both paths as arguments is what lets the self-tests
# below drive it with a fixture — without them, the assertion could only
# ever be exercised by the absence of a bug, and any mutation of this
# scanner would survive unkilled.
stale_mutations() {
  local mdir="$1" root="$2" stale="" m m_name m_file m_find m_pair m_hits tmp
  tmp=$(new_tmpdir)
  for m in "$mdir"/*.mutation; do
    [ -f "$m" ] || continue
    m_name=$(basename "$m")
    # run-mutations.sh names the mutation it currently has injected.
    # That one's FIND: is gone from its target on purpose — checking it
    # would fail on every mutation the runner tries, and for a mutation
    # whose own guard no longer fires it would become the only failure,
    # turning a clean survivor report into "went RED via the wrong
    # assertion".
    if [ -n "${ARE_MUTATION_IN_FLIGHT:-}" ] &&
       [ "$m_name" = "${ARE_MUTATION_IN_FLIGHT}.mutation" ]; then
      continue
    fi
    m_file=$(grep '^FILE:' "$m" | sed 's/^FILE://' | tail -1)
    if [ -z "$m_file" ]; then
      stale="$stale $m_name(no-FILE)"
      continue
    fi
    if [ ! -f "$root/$m_file" ]; then
      stale="$stale $m_name(no-such-file:$m_file)"
      continue
    fi
    grep '^FIND:' "$m" | sed 's/^FIND://' > "$tmp/finds"
    if [ ! -s "$tmp/finds" ]; then
      stale="$stale $m_name(no-FIND)"
      continue
    fi
    m_pair=0
    while IFS= read -r m_find; do
      m_pair=$((m_pair + 1))
      m_hits=$(grep -cFx -- "$m_find" "$root/$m_file" || true)
      if [ "$m_hits" != "1" ]; then
        stale="$stale $m_name(pair$m_pair-matches-${m_hits}-lines)"
      fi
    done < "$tmp/finds"
  done
  echo "$stale"
}

assert_equals "$(stale_mutations "$REPO_ROOT/tests/mutations" "$REPO_ROOT")" "" \
  "[all] every .mutation's FIND: still matches exactly one line of the file it names"

# --- self-tests: the scanner must report a FIND: that no longer matches,
# and stay quiet for one that does. Without these, the assertion above
# passes purely because no mutation happens to be stale today, and any
# reversion of the scanner itself would go unnoticed. ---
sc_mut_root=$(new_tmpdir)
mkdir -p "$sc_mut_root/src" "$sc_mut_root/muts"
printf 'alpha\nbeta\n' > "$sc_mut_root/src/target.sh"

printf 'FILE:src/target.sh\nFIND:alpha\nREPLACE::\nEXPECT:whatever\n' \
  > "$sc_mut_root/muts/good.mutation"
sc_mut_good=$(stale_mutations "$sc_mut_root/muts" "$sc_mut_root")
assert_equals "$sc_mut_good" "" \
  "stale_mutations() self-test: a FIND: that still matches exactly one line is not reported"

printf 'FILE:src/target.sh\nFIND:gamma\nREPLACE::\nEXPECT:whatever\n' \
  > "$sc_mut_root/muts/drifted.mutation"
sc_mut_bad=$(stale_mutations "$sc_mut_root/muts" "$sc_mut_root")
assert_contains "$sc_mut_bad" "drifted.mutation(pair1-matches-0-lines)" \
  "stale_mutations() self-test: a FIND: matching nothing is reported, naming the mutation and the pair"

# -x, not a substring match: run-mutations.sh uses grep -cFx, so a FIND:
# that is only a substring of a line is drift the real runner rejects and
# this scanner must not wave through.
printf 'FILE:src/target.sh\nFIND:alph\nREPLACE::\nEXPECT:whatever\n' \
  > "$sc_mut_root/muts/substring.mutation"
sc_mut_sub=$(stale_mutations "$sc_mut_root/muts" "$sc_mut_root")
assert_contains "$sc_mut_sub" "substring.mutation(pair1-matches-0-lines)" \
  "stale_mutations() self-test: a FIND: that is only a substring of a line is reported, matching run-mutations.sh's whole-line semantics"

# --- empty-array guard: ${arr[@]+"${arr[@]}"} sites ---
# bash 3.2 errors on "${arr[@]}" under set -u when arr has zero elements
# (fixed in bash 4.4); the guarded form ${arr[@]+"${arr[@]}"} is required
# everywhere a possibly-empty array is expanded under `set -u`. There is
# no static scan for this (unlike the D4/D5 constructs above) because the
# guarded and unguarded forms differ only by the presence of `${arr[@]+…}`
# around an otherwise-identical expansion — a functional test is the only
# way to catch a reversion. harness.sh's cleanup_tmpdirs() is exercised by
# every test file — and the array it guards is empty on every one of those
# runs, not just this one: every call site is `d=$(new_tmpdir)`, so the
# append lands in a subshell and never reaches the parent's array (see the
# registry test below). The guarded expansion is the only thing keeping
# that from erroring under set -u, and this exercises it deliberately
# rather than by accident.
sc_emptyarr_out=$(
  set -uo pipefail
  # shellcheck disable=SC1090
  . "$REPO_ROOT/tests/lib/harness.sh"
  cleanup_tmpdirs
  echo OK
)
assert_equals "$sc_emptyarr_out" "OK" \
  "harness.sh: cleanup_tmpdirs() does not error on an empty TEST_TMPDIRS array under set -u"

# path_without_command has to keep the OTHER executables in a directory
# reachable, not merely leave the named one out of the mirror. That is
# not automatic: on Windows, creating a symlink needs Developer Mode or
# SeCreateSymbolicLinkPrivilege, so `ln -s` returns EPERM for every
# entry and an unchecked `ln -s dir/* mirror/` yields a mirror with no
# executables in it at all. The suite stayed green through that only
# because the directory holding python3 there happened to contain
# nothing check-deps.sh needs — the same accident-of-layout reasoning
# that produced the bug this helper exists to fix.
#
# Driven through a fixture directory rather than the real PATH so the
# assertion means the same thing on both platforms.
sc_pwc_src=$(new_tmpdir)
make_stub_bin "$sc_pwc_src" python3 'exit 49'
make_stub_bin "$sc_pwc_src" aretest_marker 'echo MARKER_RAN'
sc_pwc_oldpath="$PATH"
PATH="$sc_pwc_src:$PATH"
sc_pwc_path=$(path_without_command python3)
PATH="$sc_pwc_oldpath"
sc_pwc_marker=$(PATH="$sc_pwc_path" aretest_marker 2>/dev/null || echo MARKER_LOST)
assert_equals "$sc_pwc_marker" "MARKER_RAN" \
  "[all] harness.sh: path_without_command keeps the directory's other executables runnable, not just absent from the mirror"
sc_pwc_py3=$(PATH="$sc_pwc_path" command -v python3 2>/dev/null || echo NONE)
assert_equals "$sc_pwc_py3" "NONE" \
  "[all] harness.sh: path_without_command leaves the named command unresolvable anywhere on the returned PATH"

# The overwhelmingly common call shape is `d=$(new_tmpdir)` — a command
# substitution, so the TEST_TMPDIRS append happens in a subshell and dies
# with it. Before new_tmpdir also recorded the path in a registry file,
# cleanup_tmpdirs therefore walked an array that was still empty and
# removed nothing: 110 call sites across 8 test files, one leaked
# directory each per run, and run-mutations.sh runs the suite 50-odd
# times. TMPDIR on the machine where this was noticed held 106,726 stale
# aretest-* directories.
#
# Run in a separate bash process, not a subshell, so it gets its own $$
# and therefore its own registry file rather than clearing this file's.
sc_leak_dir=$(bash -c '
  set -uo pipefail
  . "$1/tests/lib/harness.sh"
  d=$(new_tmpdir)
  cleanup_tmpdirs
  echo "$d"
' _ "$REPO_ROOT")
if [ -d "$sc_leak_dir" ]; then
  sc_leak_state=leaked
else
  sc_leak_state=removed
fi
assert_equals "$sc_leak_state" "removed" \
  "[all] harness.sh: cleanup_tmpdirs() removes a directory registered from inside a command substitution (the shape every call site uses)"
rm -rf "$sc_leak_dir"

cleanup_tmpdirs
print_summary
