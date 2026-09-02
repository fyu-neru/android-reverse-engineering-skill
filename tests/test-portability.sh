#!/usr/bin/env bash
# Static portability guards: the scripts must run on stock macOS
# (/bin/bash 3.2, BSD find/grep/sed). These greps prevent regressions.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"

CASE_MOD_REGEX='\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,{1,2}|\^{1,2})\}'

# scan_hits <dir> <extended-regex>
# Prints grep -nE hits for <regex> across *.sh under <dir>, with full-line
# comments filtered out (a line that is nothing but a comment, once leading
# whitespace is stripped, starts with '#'). Known limitation: a trailing
# comment on an otherwise real code line is still matched — that's
# acceptable, since a construct in a trailing comment sits right next to
# real code and is worth a second look anyway.
scan_hits() {
  local dir="$1" regex="$2"
  grep -nHE "$regex" "$dir"/*.sh 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true
}

# scan <label> <extended-regex>
# Fails when any *.sh under SCRIPT_DIR matches the regex (outside full-line
# comments).
scan() {
  local label="$1" regex="$2" hits
  hits=$(scan_hits "$SCRIPT_DIR" "$regex")
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

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
