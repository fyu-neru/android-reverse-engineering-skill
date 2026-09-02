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

# --- empty-array guard: ${arr[@]+"${arr[@]}"} sites ---
# bash 3.2 errors on "${arr[@]}" under set -u when arr has zero elements
# (fixed in bash 4.4); the guarded form ${arr[@]+"${arr[@]}"} is required
# everywhere a possibly-empty array is expanded under `set -u`. There is
# no static scan for this (unlike the D4/D5 constructs above) because the
# guarded and unguarded forms differ only by the presence of `${arr[@]+…}`
# around an otherwise-identical expansion — a functional test is the only
# way to catch a reversion. harness.sh's cleanup_tmpdirs() is exercised by
# every test file, but always with a non-empty TEST_TMPDIRS by the time it
# runs (every file calls new_tmpdir() at least once first), so the empty
# case needs its own direct exercise here.
sc_emptyarr_out=$(
  set -uo pipefail
  # shellcheck disable=SC1090
  . "$REPO_ROOT/tests/lib/harness.sh"
  cleanup_tmpdirs
  echo OK
)
assert_equals "$sc_emptyarr_out" "OK" \
  "harness.sh: cleanup_tmpdirs() does not error on an empty TEST_TMPDIRS array under set -u"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
