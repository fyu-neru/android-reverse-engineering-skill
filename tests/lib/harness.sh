#!/usr/bin/env bash
# harness.sh — minimal assertions and stub helpers for the plugin's tests.
#
# Sourced by every tests/test-*.sh. Deliberately dependency-free and
# bash 3.2 compatible: the scripts under test must run on stock macOS.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0
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

# skip_group <n> <reason>
# Announce a block of assertions that will not run on this host, and
# count them. The prose line is for whoever is reading the log; the
# count travels to run-tests.sh through print_summary so the total lands
# in the summary block too. Both halves are needed: a reader comparing a
# 219-assertion Windows log against a 166-assertion CI log has no way,
# from the summary alone, to tell deliberate skipping from assertions
# that quietly stopped being emitted.
skip_group() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + $1))
  echo "SKIP: $2"
}

# print_summary — every test file's final stdout line. run-tests.sh
# parses it; a file that does not print it is reported as an error
# rather than counted as a pass.
print_summary() {
  echo "SUMMARY $TESTS_RUN $TESTS_FAILED $TESTS_SKIPPED"
}

# Temp directories are registered twice, and both registrations matter.
#
# TEST_TMPDIRS is the array, and on its own it catches almost nothing:
# essentially every call site is `d=$(new_tmpdir)`, a command
# substitution, so the append happens inside a subshell and is discarded
# with it. cleanup_tmpdirs then walks an array that is still empty and
# removes nothing. There are 110 such call sites across 8 test files,
# each leaking a directory per run, and run-mutations.sh runs the suite
# 50-odd times: TMPDIR on this machine held 106,726 stale aretest-*
# directories by the time anyone looked.
#
# TEST_TMPDIR_REGISTRY is a file, so an append from inside a subshell
# survives it. $$ is the invoking shell's PID and does not change in a
# subshell, so every subshell of one test file appends to the same file.
#
# The array stays: cleanup_tmpdirs must keep working for directories
# registered in the parent shell, and its ${arr[@]+"${arr[@]}"}
# expansion is the bash-3.2 set -u guard that test-portability.sh
# asserts and d3-empty-array-harness.mutation pins.
TEST_TMPDIR_REGISTRY="${TMPDIR:-/tmp}/aretest-registry-$$"

new_tmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/aretest-XXXXXX")
  TEST_TMPDIRS[${#TEST_TMPDIRS[@]}]="$d"
  echo "$d" >> "$TEST_TMPDIR_REGISTRY" 2>/dev/null || true
  echo "$d"
}

cleanup_tmpdirs() {
  local d
  for d in ${TEST_TMPDIRS[@]+"${TEST_TMPDIRS[@]}"}; do
    rm -rf "$d"
  done
  TEST_TMPDIRS=()
  if [ -f "$TEST_TMPDIR_REGISTRY" ]; then
    while IFS= read -r d; do
      if [ -n "$d" ]; then
        rm -rf "$d"
      fi
    done < "$TEST_TMPDIR_REGISTRY"
    rm -f "$TEST_TMPDIR_REGISTRY"
  fi
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

# _mirror_one <src> <dest> — reproduce one file at <dest>, by whatever
# means this platform allows.
#
# All three tiers are load-bearing. A symlink is right on Linux and on
# MSYS's own filesystem. Windows refuses one unless the process holds
# SeCreateSymbolicLinkPrivilege or Developer Mode is on, and returns
# EPERM for every single entry otherwise — which is how the first
# version of path_without_command came to produce a mirror containing
# none of the 32 executables it was supposed to preserve, quietly,
# because the failure went to /dev/null. A hard link succeeds there and
# costs no disk space. cp is the last resort, for a destination on a
# different filesystem where a hard link is refused too.
_mirror_one() {
  ln -s "$1" "$2" 2>/dev/null || ln "$1" "$2" 2>/dev/null || cp -p "$1" "$2" 2>/dev/null
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
# So: any directory that holds <name> is replaced by a temp directory
# mirroring that directory's regular files, with <name> itself omitted.
#
# Three mirroring mechanisms are tried per file, because no single one
# works on both platforms:
#
#   ln -s   Linux, and MSYS's own filesystem.
#   ln      Windows. Creating a symlink there needs Developer Mode or
#           SeCreateSymbolicLinkPrivilege; without them `ln -s` returns
#           EPERM for every entry. Measured on the machine this was
#           written on: mirroring WindowsApps (51 entries, 32 of them
#           regular files) produced 19 empty directories and lost every
#           executable, silently, because the error was discarded. A
#           hard link succeeds for all 32 and costs no disk space.
#   cp -p   Last resort, e.g. across filesystems where a hard link is
#           refused.
#
# Directories are skipped: they cannot hold a PATH-resolvable command.
# If a directory has regular files and not one of them could be
# mirrored, the function says so and fails, rather than returning a PATH
# entry that resolves nothing — losing every tool in a directory without
# a word is the exact defect this function exists to prevent, and the
# 90 seconds it took to notice it the first time were bought by an
# `|| true` on the mirroring step.
#
# PATH entries that are not existing directories are dropped; they
# cannot resolve anything either way.
path_without_command() {
  local cmd="$1" out="" oldifs="$IFS" dir mirror f base seen mirrored globbed noglob
  case "$-" in
    *f*) noglob=already ;;
    *)   noglob=no ;;
  esac
  # A PATH entry containing * or ? is a path, not a glob.
  IFS=':'
  set -f
  set -- $PATH
  IFS="$oldifs"

  # Globbing back ON for the rest of this function, whatever the caller
  # had — the file loop below depends on it, and a caller splitting its
  # own comma-separated list under `set -f` is a normal thing to be
  # called from. Left off, "$dir"/* stays literal, `[ -f ]` is false for
  # that one string, and the mirror comes back EMPTY while every counter
  # reads zero — so the guard below sees seen=0 and reports nothing
  # wrong. That is exactly what happened: the mirrors were created,
  # contained nothing, and CI failed with `env: command not found`
  # because the returned PATH had no tools left on it at all.
  set +f

  for dir in "$@"; do
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      continue
    fi
    if [ ! -f "$dir/$cmd" ] && [ ! -f "$dir/$cmd.exe" ] &&
       [ ! -f "$dir/$cmd.bat" ] && [ ! -f "$dir/$cmd.cmd" ]; then
      out="${out:+$out:}$dir"
      continue
    fi
    mirror=$(new_tmpdir)
    seen=0
    mirrored=0
    globbed=0
    for f in "$dir"/*; do
      # An unexpanded glob is one iteration over a path that does not
      # exist, so -e distinguishes it from a real entry. Counting real
      # entries is what makes the "expanded to nothing" case below
      # detectable at all.
      [ -e "$f" ] || continue
      globbed=$((globbed + 1))
      [ -f "$f" ] || continue
      base=${f##*/}
      case "$base" in
        "$cmd"|"$cmd".exe|"$cmd".bat|"$cmd".cmd) continue ;;
      esac
      seen=$((seen + 1))
      if _mirror_one "$f" "$mirror/$base"; then
        mirrored=$((mirrored + 1))
      fi
    done
    if [ "$globbed" -eq 0 ]; then
      # This directory provably holds $cmd — that is why we are mirroring
      # it — so the glob matching nothing is impossible unless expansion
      # itself was disabled. Fail rather than return an empty mirror.
      echo "path_without_command: '$dir'/* expanded to nothing, yet that directory" >&2
      echo "  holds '$cmd'. Pathname expansion is off (set -f) somewhere it should" >&2
      echo "  not be; returning an empty mirror here would hand back a PATH with no" >&2
      echo "  tools on it." >&2
      if [ "$noglob" = "already" ]; then set -f; fi
      return 1
    fi
    if [ "$seen" -gt 0 ] && [ "$mirrored" -eq 0 ]; then
      echo "path_without_command: could not mirror any of the $seen files in $dir" >&2
      echo "  (symlink, hard link and copy all failed). Handing back a PATH that" >&2
      echo "  silently loses every tool in that directory is what this function" >&2
      echo "  exists to prevent, so it is failing instead." >&2
      if [ "$noglob" = "already" ]; then set -f; fi
      return 1
    fi
    out="${out:+$out:}$mirror"
  done
  if [ "$noglob" = "already" ]; then set -f; fi
  printf '%s\n' "$out"
}

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
