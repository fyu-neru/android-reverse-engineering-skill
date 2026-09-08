#!/usr/bin/env bash
# check-deps.sh — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL:<dep> lines for each missing dependency.
# The install-dep.sh script can install each one.
#
# Existence and resolution order (env override -> PATH probe -> candidate
# paths) for the tools listed in lib/tools.psv (java, jadx, vineflower, adb)
# comes from lib/tools.sh's tool_list, tool_resolve and tool_field, not a
# second, independently-maintained candidate-path list — see lib/tools.sh's
# header comment for the drift that duplication used to cause. dex2jar and
# apktool are no longer dependencies of this plugin (2.0.0): jadx handles
# APK/DEX/XAPK/APKM natively, so both are documented as manual fallbacks in
# references/setup-guide.md instead of being checked or installed here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"

REQUIRED_JAVA_MAJOR=17
errors=0
missing_required=()
missing_optional=()

echo "=== Android Reverse Engineering: Dependency Check ==="
echo

for _dep_id in $(tool_list required); do
  case "$_dep_id" in
    java)
      # --- Java ---
      # Resolution is delegated to tool_resolve; the version-parsing logic
      # below is not a resolution concern and is left exactly as it was.
      if java_bin=$(tool_resolve java); then
        java_version_output=$("$java_bin" -version 2>&1)
        java_version_output=${java_version_output%%$'\n'*}
        java_version=$(echo "$java_version_output" | sed -n 's/.*"\([0-9]*\)\..*/\1/p')
        if [[ -z "$java_version" ]]; then
          # BSD grep has no -P. A basic-regex sed extracts the first digit run.
          java_version=$(echo "$java_version_output" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p;q')
        fi
        if [[ "$java_version" == "1" ]]; then
          java_version=$(echo "$java_version_output" | sed -n 's/.*"1\.\([0-9]*\)\..*/\1/p')
        fi

        if [[ -n "$java_version" ]] && (( java_version >= REQUIRED_JAVA_MAJOR )); then
          echo "[OK] Java $java_version detected"
        else
          echo "[WARN] Java detected but version $java_version is below $REQUIRED_JAVA_MAJOR"
          errors=$((errors + 1))
          missing_required+=("java")
        fi
      else
        echo "[MISSING] Java is not installed or not in PATH"
        errors=$((errors + 1))
        missing_required+=("java")
      fi
      ;;
    jadx)
      # --- jadx ---
      if jadx_bin=$(tool_resolve jadx); then
        jadx_version=$("$jadx_bin" --version 2>/dev/null || echo "unknown")
        echo "[OK] jadx $jadx_version detected"
      else
        echo "[MISSING] jadx is not installed or not in PATH"
        errors=$((errors + 1))
        missing_required+=("jadx")
      fi
      ;;
    *)
      # Generic fallback for a future required row tools.psv gains before
      # this script grows a dedicated case for it.
      if tool_resolve "$_dep_id" >/dev/null; then
        echo "[OK] $_dep_id detected"
      else
        echo "[MISSING] $_dep_id is not installed or not in PATH"
        errors=$((errors + 1))
        missing_required+=("$_dep_id")
      fi
      ;;
  esac
done

for _dep_id in $(tool_list optional); do
  case "$_dep_id" in
    vineflower)
      # --- Vineflower ---
      # tool_resolve owns the resolution order (env override -> PATH probe
      # -> candidate paths); this block only figures out WHICH of those
      # three kinds of match tool_resolve made, so each kind can keep its
      # original wording ("<cli> CLI detected" vs "JAR found: <path>").
      ff_purpose=$(tool_field vineflower purpose)
      if ff_path=$(tool_resolve vineflower); then
        ff_env_name=$(tool_field vineflower env_override)
        ff_env_val=""
        if [[ "$ff_env_name" != "-" ]]; then
          ff_env_val=${!ff_env_name:-}
        fi
        ff_matched_probe=""
        if [[ -z "$ff_env_val" ]] || [[ "$ff_path" != "$ff_env_val" ]]; then
          ff_probe=$(tool_field vineflower probe)
          ff_oldifs="$IFS"
          IFS=','
          for ff_p in $ff_probe; do
            IFS="$ff_oldifs"
            if [[ "$(command -v "$ff_p" 2>/dev/null || true)" == "$ff_path" ]]; then
              ff_matched_probe="$ff_p"
              break
            fi
            IFS=','
          done
          IFS="$ff_oldifs"
        fi
        if [[ -n "$ff_matched_probe" ]]; then
          echo "[OK] $ff_matched_probe CLI detected"
        else
          echo "[OK] Vineflower JAR found: $ff_path"
        fi
      else
        echo "[MISSING] Vineflower not found (optional — $ff_purpose)"
        missing_optional+=("vineflower")
      fi
      ;;
    adb)
      # --- Optional: adb ---
      if tool_resolve adb >/dev/null; then
        echo "[OK] adb detected (optional)"
      else
        adb_purpose=$(tool_field adb purpose)
        echo "[MISSING] adb not found (optional — $adb_purpose)"
        missing_optional+=("adb")
      fi
      ;;
    python3)
      # --- Optional: python3 (D7) ---
      # recover-kotlin-names.sh and lookup-name.sh are internally embedded
      # Python, but nothing declared that dependency before this row — they
      # failed outright on a machine with no working interpreter while this
      # script reported everything fine.
      #
      # Resolving via tool_resolve only proves that something NAMED python3
      # exists on PATH or a candidate — it does not prove there is a working
      # interpreter behind it. On Windows, `python3` is commonly the
      # Microsoft Store's app-execution-alias stub: it resolves via PATH,
      # but running it exits non-zero with no version output at all (typing
      # `python3` at a prompt with no args instead opens the Store). A bare
      # existence check cannot tell that apart from a real interpreter, so
      # this actually runs one.
      # tool_resolve now runs each probe hit before accepting it (the
      # python3 row carries verify=python3), so it walks past the Store
      # stub to the next name in the list. An explicit PYTHON3_BIN is
      # still honoured as given, so the interpreter check below stays —
      # it is what keeps the [OK] line honest on that path.
      py3_purpose=$(tool_field python3 purpose)
      if py3_bin=$(tool_resolve python3); then
        if py3_check_output=$("$py3_bin" -c 'import sys; print(sys.version_info[0])' 2>/dev/null); then
          py3_check_status=0
        else
          py3_check_status=$?
        fi
        if [[ $py3_check_status -eq 0 ]] && [[ "$py3_check_output" == "3" ]]; then
          py3_full=$("$py3_bin" -c 'import platform; print(platform.python_version())' 2>/dev/null) || py3_full="3"
          echo "[OK] python3 $py3_full detected"
        else
          echo "[MISSING] python3 was found at $py3_bin but is not a working interpreter (exit $py3_check_status) — optional, $py3_purpose. On Windows, a \"python3\" that opens the Microsoft Store instead of running is this stub, not a real interpreter."
          missing_optional+=("python3")
        fi
      else
        # Resolution failing now means every name in the probe list
        # either did not exist or did not answer as Python 3. If one of
        # them does exist, name it: telling someone "not found" when
        # they can see python3 on their own PATH sends them looking for
        # the wrong problem entirely.
        py3_found=""
        py3_probe=$(tool_field python3 probe) || py3_probe="-"
        py3_oldifs="$IFS"
        py3_oldopts="$-"
        IFS=','
        # set -f for the same reason every other comma/semicolon split in
        # this plugin does it: an unquoted expansion is subject to
        # pathname expansion as well as word splitting, so a probe value
        # containing a glob character would be rewritten into whatever
        # happened to match in the current directory.
        set -f
        for py3_name in $py3_probe; do
          IFS="$py3_oldifs"
          if [ -n "$py3_name" ] && [ "$py3_name" != "-" ] &&
             py3_where=$(command -v "$py3_name" 2>/dev/null); then
            py3_found="$py3_where"
            break
          fi
          IFS=','
        done
        IFS="$py3_oldifs"
        case "$py3_oldopts" in *f*) ;; *) set +f ;; esac
        if [ -n "$py3_found" ]; then
          if "$py3_found" -c 'import sys' >/dev/null 2>&1; then
            py3_found_status=0
          else
            py3_found_status=$?
          fi
          echo "[MISSING] python3 was found at $py3_found but is not a working interpreter (exit $py3_found_status) — optional, $py3_purpose. On Windows, a \"python3\" that opens the Microsoft Store instead of running is this stub, not a real interpreter; python.org's installer provides \"python\" and never \"python3\"."
        else
          echo "[MISSING] python3 not found (optional — $py3_purpose)"
        fi
        missing_optional+=("python3")
      fi
      ;;
    *)
      # Generic fallback for a future optional row tools.psv gains before
      # this script grows a dedicated case for it.
      if tool_resolve "$_dep_id" >/dev/null; then
        echo "[OK] $_dep_id detected (optional)"
      else
        _dep_purpose=$(tool_field "$_dep_id" purpose)
        echo "[MISSING] $_dep_id not found (optional — $_dep_purpose)"
        missing_optional+=("$_dep_id")
      fi
      ;;
  esac
done

# --- Machine-readable summary ---
echo
if [[ ${#missing_required[@]} -gt 0 ]]; then
  for dep in "${missing_required[@]}"; do
    echo "INSTALL_REQUIRED:$dep"
  done
fi
if [[ ${#missing_optional[@]} -gt 0 ]]; then
  for dep in "${missing_optional[@]}"; do
    echo "INSTALL_OPTIONAL:$dep"
  done
fi

echo
if (( errors > 0 )); then
  echo "*** ${#missing_required[@]} required dependency/ies missing. ***"
  echo "Run install-dep.sh <name> to install, or see references/setup-guide.md."
  exit 1
else
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    echo "Required dependencies OK. ${#missing_optional[@]} optional dependency/ies missing."
    echo "Run install-dep.sh <name> to install optional tools."
  else
    echo "All dependencies are installed. Ready to decompile."
  fi
  exit 0
fi
