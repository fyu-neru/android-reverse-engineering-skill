#!/usr/bin/env bash
# check-deps.sh — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL:<dep> lines for each missing dependency.
# The install-dep.sh script can install each one.
#
# Existence and resolution order (env override -> PATH probe -> candidate
# paths) for the tools listed in lib/tools.psv (java, jadx, vineflower, adb)
# comes from lib/tools.sh's tool_list/tool_resolve/tool_field rather than a
# second, independently-maintained candidate-path list — see lib/tools.sh's
# header comment for the drift that duplication used to cause. dex2jar and
# apktool are not yet in tools.psv (they are dropped from the plugin
# entirely in a later 2.0.0 task) and keep their original hardcoded checks,
# unchanged, in their original output position.
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
      # --- Fernflower / Vineflower ---
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
          echo "[OK] Fernflower/Vineflower JAR found: $ff_path"
        fi
      else
        echo "[MISSING] Fernflower/Vineflower not found (optional — $ff_purpose)"
        missing_optional+=("vineflower")
      fi

      # --- dex2jar ---
      # Not yet in tools.psv (dropped from the plugin entirely in a later
      # 2.0.0 task); kept hardcoded here, in its original output position
      # between vineflower and apktool.
      if command -v d2j-dex2jar &>/dev/null || command -v d2j-dex2jar.sh &>/dev/null; then
        echo "[OK] dex2jar detected"
      else
        echo "[MISSING] dex2jar not found (optional — needed to use Fernflower on APK/DEX files)"
        missing_optional+=("dex2jar")
      fi

      # --- Optional: apktool ---
      # Not yet in tools.psv (dropped from the plugin entirely in a later
      # 2.0.0 task); kept hardcoded here, in its original output position.
      if command -v apktool &>/dev/null; then
        echo "[OK] apktool detected (optional)"
      else
        echo "[MISSING] apktool not found (optional — useful for resource decoding)"
        missing_optional+=("apktool")
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
