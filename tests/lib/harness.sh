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

# host_is_really_windows — the raw uname test, with no override. Use it
# where the question is about this machine's actual filesystem layout
# rather than about which assertions ought to run.
host_is_really_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
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
# Windows/MSYS machine without needing a Linux box. It simulates which
# assertions run; it cannot simulate where python3 lives, which is why
# host_is_really_windows exists alongside it.
is_windows_host() {
  if [ "${ARE_TESTS_FORCE_NOT_WINDOWS:-}" = "1" ]; then
    return 1
  fi
  host_is_really_windows
}

# path_without_command <name> — a PATH on which <name> cannot resolve,
# built WITHOUT dropping whole directories.
#
# The obvious implementation — filter out every PATH entry that contains
# <name> — is a trap, and it is how the python3 checks broke on CI: on
# Linux python3 lives in /usr/bin, so filtering takes grep, sed and
# dirname with it. The script under test then does not run without
# python3, it does not run at all, and an assertion looking for
# "[MISSING] python3" in its output fails against an empty string while
# a companion assert_not_contains passes vacuously against that same
# empty string. On Windows the same code looked fine, because there
# python3 is a Store alias in a directory of its own.
#
# So: any directory that holds <name> is replaced by a temp directory of
# symlinks to that directory's contents with <name> itself omitted.
# Everything else in it stays reachable. One ln(1) call per affected
# directory, not one per file.
path_without_command() {
  _pwc_cmd="$1"
  _pwc_out=""
  _pwc_oldifs="$IFS"
  IFS=':'
  for _pwc_dir in $PATH; do
    IFS="$_pwc_oldifs"
    if [ -n "$_pwc_dir" ] && [ -d "$_pwc_dir" ]; then
      if [ -f "$_pwc_dir/$_pwc_cmd" ] || [ -f "$_pwc_dir/$_pwc_cmd.exe" ] ||
         [ -f "$_pwc_dir/$_pwc_cmd.bat" ] || [ -f "$_pwc_dir/$_pwc_cmd.cmd" ]; then
        _pwc_mirror=$(new_tmpdir)
        ln -s "$_pwc_dir"/* "$_pwc_mirror/" 2>/dev/null || true
        rm -f "$_pwc_mirror/$_pwc_cmd" "$_pwc_mirror/$_pwc_cmd.exe" \
              "$_pwc_mirror/$_pwc_cmd.bat" "$_pwc_mirror/$_pwc_cmd.cmd"
        _pwc_out="${_pwc_out:+$_pwc_out:}$_pwc_mirror"
      else
        _pwc_out="${_pwc_out:+$_pwc_out:}$_pwc_dir"
      fi
    fi
    IFS=':'
  done
  IFS="$_pwc_oldifs"
  printf '%s\n' "$_pwc_out"
}
