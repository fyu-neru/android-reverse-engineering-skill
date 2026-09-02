#!/usr/bin/env bash
# Static portability guards: the scripts must run on stock macOS
# (/bin/bash 3.2, BSD find/grep/sed). These greps prevent regressions.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"

# scan <label> <extended-regex>
# Fails when any *.sh under SCRIPT_DIR matches the regex.
scan() {
  local label="$1" regex="$2" hits
  hits=$(grep -nE "$regex" "$SCRIPT_DIR"/*.sh 2>/dev/null || true)
  assert_equals "$hits" "" "$label"
}

# --- D5: bash 4+ only constructs ---
scan "no associative arrays (bash 4+)" 'declare -A|local -A'
scan "no case-modification expansion (bash 4+)" '\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,,|\^\^)\}'
scan "no mapfile/readarray (bash 4+)" '\b(mapfile|readarray)\b'
scan "no namerefs (bash 4.3+)" 'declare -n|local -n'

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
