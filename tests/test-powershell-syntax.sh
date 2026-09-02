#!/usr/bin/env bash
# Regression guard: every .ps1 under the plugin's scripts/ directory must
# parse with no syntax errors. This is the PowerShell-side counterpart to
# the bash portability guard — bash/PowerShell divergence is exactly the
# class of defect this release fixed (a PowerShell function rename, a new
# return shape, a new dispatch branch — none of it exercised by any
# existing bash test).
#
# PowerShell is optional: this repo's tests must keep running on a machine
# with no PowerShell installed (that's the whole point of the portability
# work). If neither `pwsh` nor `powershell` is on PATH, skip cleanly and
# report zero assertions rather than failing the suite.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"

PWSH_BIN=""
if command -v pwsh >/dev/null 2>&1; then
  PWSH_BIN="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  PWSH_BIN="powershell"
fi

if [ -z "$PWSH_BIN" ]; then
  echo "SKIP: neither pwsh nor powershell found on PATH; skipping PowerShell syntax checks."
  echo "SUMMARY 0 0"
  exit 0
fi

# A tiny wrapper script, run under the found interpreter, that uses the
# language parser to check one file for syntax errors without executing
# it. Writing this to a file (rather than passing it as -Command text)
# avoids quoting/escaping the target path, which may contain spaces.
parse_dir=$(new_tmpdir)
parser_script="$parse_dir/parse-check.ps1"
cat > "$parser_script" <<'EOF'
param([Parameter(Mandatory=$true)][string]$Path)
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($e in $parseErrors) { Write-Output $e.ToString() }
    exit 1
}
exit 0
EOF

for f in "$SCRIPT_DIR"/*.ps1; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  out=$("$PWSH_BIN" -NoProfile -NonInteractive -File "$parser_script" -Path "$f" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    _pass "$name parses with no syntax errors"
  else
    _fail "$name parses with no syntax errors" "$out"
  fi
done

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
