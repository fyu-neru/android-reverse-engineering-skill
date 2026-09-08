#!/usr/bin/env bash
# tools.sh — the single source of truth for locating the plugin's tools.
#
# Sourced by check-deps.sh, decompile.sh and install-dep.sh. Before this
# existed the candidate-path list was copy-pasted into five places and had
# already drifted: decompile.sh could not find the jar install-dep.sh had
# just installed.
#
# bash 3.2 compatible: no associative arrays, no case-modification
# expansions, no mapfile, no namerefs.

_tools_psv() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/android-reverse-engineering/scripts/lib/tools.psv" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT/skills/android-reverse-engineering/scripts/lib/tools.psv"
    return 0
  fi
  # Fallback: alongside this file. Breaks under a symlinked invocation,
  # which is why CLAUDE_PLUGIN_ROOT is preferred.
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools.psv"
}

# tool_field <id> <column-name>
# Prints the raw field, or returns 1 if the id or column is unknown.
tool_field() {
  local want_id="$1" want_col="$2" psv header
  psv=$(_tools_psv)
  [ -f "$psv" ] || return 1

  IFS= read -r header < "$psv"
  # A tools.psv saved with CRLF line endings (e.g. by a Windows editor, with
  # no .gitattributes normalization in effect) leaves a trailing \r on every
  # line `read` returns — bash's `read -r` strips the trailing newline but
  # not a preceding \r. Left in place, the header's LAST field becomes
  # "purpose\r", which never equals the bareword "purpose" a caller asks
  # for, so every last-column lookup fails outright on Unix while
  # PowerShell's regex-based line splitter (\r\n|\n) is unaffected. Strip it
  # with a bash-3.2-safe parameter expansion (no case-modification, no
  # external tool) so both readers tolerate the same file.
  header="${header%$'\r'}"
  local idx=0 found=-1 col
  local oldifs="$IFS" oldopts="$-"
  IFS='|'
  set -f
  for col in $header; do
    if [ "$col" = "$want_col" ]; then found=$idx; fi
    idx=$((idx + 1))
  done
  IFS="$oldifs"
  case "$oldopts" in *f*) ;; *) set +f ;; esac
  [ "$found" -ge 0 ] || return 1

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "$want_id"'|'*) ;;
      *) continue ;;
    esac
    local i=0 f
    oldifs="$IFS"; IFS='|'
    oldopts="$-"
    set -f
    for f in $line; do
      if [ "$i" -eq "$found" ]; then
        IFS="$oldifs"
        case "$oldopts" in *f*) ;; *) set +f ;; esac
        printf '%s\n' "$f"; return 0
      fi
      i=$((i + 1))
    done
    IFS="$oldifs"
    case "$oldopts" in *f*) ;; *) set +f ;; esac
  done < "$psv"
  return 1
}

_tools_expand() {
  # Expand {HOME} and {LOCALAPPDATA} in a candidate path. Deliberately not
  # eval.
  #
  # {LOCALAPPDATA} exists so a single candidates list can carry Windows-only
  # locations (spelled with the .bat extension Windows actually needs,
  # resolved against %LOCALAPPDATA%) alongside Unix locations in the same
  # tools.psv row: both readers only test file existence, so a Windows-only
  # candidate simply never matches on Unix and vice versa - no
  # platform-column branching required (fix round 1, Finding 1). $LOCALAPPDATA
  # is normally unset outside Windows, in which case it expands to the empty
  # string and the resulting candidate (a path with a bare leading "/")
  # simply fails the existence test below, exactly like any other
  # non-existent candidate.
  #
  # NOT cross-reader tested as a raw string: bash's $HOME/$LOCALAPPDATA and
  # PowerShell's $env:USERPROFILE/$env:LOCALAPPDATA are different literal
  # strings even on the same Git-Bash-on-Windows machine (e.g. /c/Users/foo
  # vs C:\Users\foo), so comparing the two readers' *default-derived*
  # expansion verbatim is structurally meaningless - it would "diverge"
  # even when both are correct. tests/test-tools-psv.sh's Group 7
  # instead points both readers' home-directory/local-appdata variables at
  # the same native directory and checks they resolve to the same file -
  # see the matching comment on Expand-ToolPlaceholders in Tools.ps1.
  local s="$1"
  s="${s//\{HOME\}/$HOME}"
  s="${s//\{LOCALAPPDATA\}/${LOCALAPPDATA:-}}"
  printf '%s\n' "$s"
}

# tool_resolve <id>
# Prints the single artifact path (an executable or a .jar). Returns 1 if
# the tool cannot be found. Safe to quote.
# _tools_verify_python3 <path>
# True only when <path> is a working Python 3.
#
# Presence is not evidence here. Windows ships a Microsoft Store
# app-execution alias named python3 in %LOCALAPPDATA%\Microsoft\
# WindowsApps: a real 331KB file that `command -v` finds and that exits
# 49 with no output, opening the Store when run from a prompt. And
# python.org's Windows installer creates python.exe and pythonw.exe but
# never a python3.exe — only a python3.dll — so on Windows the NAME
# python3 can resolve to the stub and to nothing else, however many real
# interpreters are installed. Measured on the machine this was written
# on, with Python 3.12.10 installed: python3 -> the stub, exit 49;
# python -> the real interpreter, exit 0.
_tools_verify_python3() {
  local out
  out=$("$1" -c 'import sys; print(sys.version_info[0])' 2>/dev/null) || return 1
  [ "$out" = "3" ]
}

# _tools_accept <id> <path>
# True when <path> is not merely present but usable as <id>.
#
# Only consulted for probe hits and candidate paths — the guesses. An
# explicit env override is a statement of intent and is honoured as
# given; second-guessing it would silently substitute a different tool
# for the one the caller named. Consumers that care (check-deps.sh) run
# their own check on whatever they were handed and report on it.
_tools_accept() {
  local id="$1" path="$2" verify
  verify=$(tool_field "$id" verify) || return 0
  case "$verify" in
    -|'') return 0 ;;
    python3) _tools_verify_python3 "$path" ;;
    *)
      # An unrecognised verifier name is a manifest error. Accepting
      # anyway would silently downgrade to no verification at all, which
      # is the failure this column exists to prevent.
      echo "tools.sh: tools.psv names an unknown verify '$verify' for tool '$id'" >&2
      return 1
      ;;
  esac
}

tool_resolve() {
  local id="$1" env_name env_val probe candidates cand
  env_name=$(tool_field "$id" env_override) || return 1
  if [ "$env_name" != "-" ]; then
    # Indirect expansion, not eval: ${!env_name:-} looks up the variable
    # NAMED by $env_name and defaults to empty if that variable (or
    # env_name itself) is unset. Supported since bash 2.0, so this is
    # bash-3.2 safe.
    env_val=${!env_name:-}
    if [ -n "$env_val" ] && [ -f "$env_val" ]; then
      printf '%s\n' "$env_val"; return 0
    fi
  fi

  probe=$(tool_field "$id" probe) || return 1
  if [ "$probe" != "-" ]; then
    local oldifs="$IFS" oldopts="$-" p p_path
    IFS=','
    set -f
    for p in $probe; do
      IFS="$oldifs"
      # Keep going past a name that exists but does not work: on Windows
      # the first name in python3's probe list resolves to the Store stub
      # every time, and stopping there reported [MISSING] on machines
      # with a working Python installed under a different name.
      if p_path=$(command -v "$p" 2>/dev/null) && _tools_accept "$id" "$p_path"; then
        case "$oldopts" in *f*) ;; *) set +f ;; esac
        printf '%s\n' "$p_path"; return 0
      fi
      IFS=','
    done
    IFS="$oldifs"
    case "$oldopts" in *f*) ;; *) set +f ;; esac
  fi

  candidates=$(tool_field "$id" candidates) || return 1
  if [ "$candidates" != "-" ]; then
    local oldifs="$IFS" oldopts="$-" c
    IFS=';'
    set -f
    for c in $candidates; do
      IFS="$oldifs"
      # An empty element (e.g. a stray ";;" in the candidates list) is
      # skipped explicitly rather than relying on `[ -f "" ]` happening to
      # be false — see the matching comment in Tools.ps1's Resolve-Tool,
      # where PowerShell's Test-Path throws on an empty path under
      # $ErrorActionPreference = 'Stop' and needs the same skip to avoid
      # aborting before a later candidate this reader would still find.
      if [ -z "$c" ]; then
        IFS=';'
        continue
      fi
      cand=$(_tools_expand "$c")
      if [ -f "$cand" ] && _tools_accept "$id" "$cand"; then
        case "$oldopts" in *f*) ;; *) set +f ;; esac
        printf '%s\n' "$cand"; return 0
      fi
      IFS=';'
    done
    IFS="$oldifs"
    case "$oldopts" in *f*) ;; *) set +f ;; esac
  fi
  return 1
}

# tool_argv <id>
# Fills the global indexed array TOOL_ARGV with the command to run the
# tool. An argv array rather than a joined string: paths routinely contain
# spaces and a joined string cannot be expanded safely.
TOOL_ARGV=()
tool_argv() {
  local id="$1" kind path java
  TOOL_ARGV=()
  path=$(tool_resolve "$id") || return 1
  kind=$(tool_field "$id" kind) || return 1

  if [ "$kind" = "jar" ]; then
    # A jar-kind tool can still resolve to a real CLI executable when the
    # PATH probe finds one (e.g. a package manager's `vineflower` launcher
    # script) rather than the raw .jar this project's own installer
    # places at the candidate paths. tool_resolve's env-override and
    # candidate matches are always the literal jar named in tools.psv, but
    # a probe match is whatever the probe name resolved to on PATH -- run
    # it directly instead of wrapping it in `java -jar`. This mirrors the
    # match-kind disambiguation check-deps.sh already does for its own
    # output wording; without it, a CLI found on PATH gets handed to
    # `java -jar <CLI path>`, which fails immediately.
    local probe p matched_probe="" oldifs oldopts
    probe=$(tool_field "$id" probe) || return 1
    if [ "$probe" != "-" ]; then
      oldifs="$IFS"; oldopts="$-"
      IFS=','
      set -f
      for p in $probe; do
        IFS="$oldifs"
        if [ "$(command -v "$p" 2>/dev/null)" = "$path" ]; then
          matched_probe="$p"
          IFS=','
          break
        fi
        IFS=','
      done
      IFS="$oldifs"
      case "$oldopts" in *f*) ;; *) set +f ;; esac
    fi

    if [ -n "$matched_probe" ]; then
      TOOL_ARGV=("$path")
      return 0
    fi

    java=$(tool_resolve java) || return 1
    TOOL_ARGV=("$java" -jar "$path")
  else
    TOOL_ARGV=("$path")
  fi
  return 0
}

tool_run() {
  local id="$1"; shift
  tool_argv "$id" || return 1
  "${TOOL_ARGV[@]}" ${@+"$@"}
}

# tool_list [required|optional]
tool_list() {
  local want="${1:-}" psv line id req
  psv=$(_tools_psv)
  [ -f "$psv" ] || return 1
  local first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then first=0; continue; fi
    case "$line" in ''|'#'*) continue ;; esac
    id=${line%%|*}
    case "$id" in '#'*) continue ;; esac
    if [ -n "$want" ]; then
      req=$(tool_field "$id" required)
      [ "$req" = "$want" ] || continue
    fi
    printf '%s\n' "$id"
  done < "$psv"
}
