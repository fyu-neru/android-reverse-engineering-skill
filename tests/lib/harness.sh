#!/usr/bin/env bash
# harness.sh — minimal assertions and stub helpers for the plugin's tests.
#
# Sourced by every tests/test-*.sh. Deliberately dependency-free and
# bash 3.2 compatible: the scripts under test must run on stock macOS.

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMPDIRS=()

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  ok   - $1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL - $1"
  if [ -n "${2:-}" ]; then
    echo "         $2"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *)      _fail "$3" "expected to find: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _fail "$3" "expected NOT to find: $2" ;;
    *)      _pass "$3" ;;
  esac
}

assert_equals() {
  if [ "$1" = "$2" ]; then
    _pass "$3"
  else
    _fail "$3" "expected [$2] but got [$1]"
  fi
}

new_tmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/aretest-XXXXXX")
  TEST_TMPDIRS[${#TEST_TMPDIRS[@]}]="$d"
  echo "$d"
}

cleanup_tmpdirs() {
  local d
  for d in ${TEST_TMPDIRS[@]+"${TEST_TMPDIRS[@]}"}; do
    rm -rf "$d"
  done
  TEST_TMPDIRS=()
}

# make_stub_bin <dir> <name> <body>
# Creates an executable stub so tests can drive scripts that shell out to
# java / jadx / unzip without those tools actually being present.
make_stub_bin() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    echo "$body"
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

# is_windows_host — true only when this shell is running on an actual
# Windows host (Git-Bash/MSYS2, Cygwin), where Windows executable
# resolution (PATHEXT finding a .cmd/.bat via `Get-Command
# -CommandType Application`) and Windows-rooted paths/env vars
# (C:\..., USERPROFILE) genuinely apply.
#
# This is deliberately NOT "does a pwsh/powershell interpreter exist on
# PATH" — ubuntu-latest ships pwsh, so that gate let [win]-labeled
# assertions run on Linux, where their .cmd/.bat stubs cannot execute
# and USERPROFILE/C:\ paths mean nothing. The [win] blocks need "are we
# on Windows", not "can we launch a PowerShell interpreter here".
#
# ARE_TESTS_FORCE_NOT_WINDOWS=1 forces this to report false regardless
# of the actual host, so the reduced-coverage Linux/CI path (the [win]
# blocks visibly SKIP:) can be exercised and verified from a real
# Windows/MSYS machine without needing a Linux box.
is_windows_host() {
  if [ "${ARE_TESTS_FORCE_NOT_WINDOWS:-}" = "1" ]; then
    return 1
  fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}
