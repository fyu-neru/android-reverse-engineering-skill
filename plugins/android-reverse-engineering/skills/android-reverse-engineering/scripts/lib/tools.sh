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
  local idx=0 found=-1 col
  local oldifs="$IFS"
  IFS='|'
  for col in $header; do
    if [ "$col" = "$want_col" ]; then found=$idx; fi
    idx=$((idx + 1))
  done
  IFS="$oldifs"
  [ "$found" -ge 0 ] || return 1

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$want_id"'|'*) ;;
      *) continue ;;
    esac
    local i=0 f
    oldifs="$IFS"; IFS='|'
    for f in $line; do
      if [ "$i" -eq "$found" ]; then IFS="$oldifs"; printf '%s\n' "$f"; return 0; fi
      i=$((i + 1))
    done
    IFS="$oldifs"
  done < "$psv"
  return 1
}

_tools_expand() {
  # Expand {HOME} in a candidate path. Deliberately not eval.
  local s="$1"
  printf '%s\n' "${s//\{HOME\}/$HOME}"
}

# tool_resolve <id>
# Prints the single artifact path (an executable or a .jar). Returns 1 if
# the tool cannot be found. Safe to quote.
tool_resolve() {
  local id="$1" env_name env_val probe candidates cand
  env_name=$(tool_field "$id" env_override) || return 1
  if [ "$env_name" != "-" ]; then
    eval "env_val=\${$env_name:-}"
    if [ -n "$env_val" ] && [ -f "$env_val" ]; then
      printf '%s\n' "$env_val"; return 0
    fi
  fi

  probe=$(tool_field "$id" probe) || return 1
  if [ "$probe" != "-" ]; then
    local oldifs="$IFS" p
    IFS=','
    for p in $probe; do
      IFS="$oldifs"
      if command -v "$p" >/dev/null 2>&1; then
        command -v "$p"; return 0
      fi
      IFS=','
    done
    IFS="$oldifs"
  fi

  candidates=$(tool_field "$id" candidates) || return 1
  if [ "$candidates" != "-" ]; then
    local oldifs="$IFS" c
    IFS=';'
    for c in $candidates; do
      IFS="$oldifs"
      cand=$(_tools_expand "$c")
      if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
      IFS=';'
    done
    IFS="$oldifs"
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
