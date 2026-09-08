# check-deps.ps1 — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL_REQUIRED/INSTALL_OPTIONAL lines.
#
# Existence and resolution order (env override -> PATH probe -> candidate
# paths) for the tools listed in lib/tools.psv (java, jadx, vineflower, adb)
# comes from lib/Tools.ps1's Get-ToolList/Resolve-Tool/Get-ToolField rather
# than a second, independently-maintained candidate-path list. dex2jar and
# apktool are no longer dependencies of this plugin (2.0.0): jadx handles
# APK/DEX/XAPK/APKM natively, so both are documented as manual fallbacks in
# references/setup-guide.md instead of being checked or installed here.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/Tools.ps1')

# Refresh PATH from user environment so we pick up tools installed in the same session
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath) {
    foreach ($dir in $userPath -split ';') {
        if ($dir -and $env:PATH -notlike "*$dir*") {
            $env:PATH = "$dir;$env:PATH"
        }
    }
}

$REQUIRED_JAVA_MAJOR = 17
$errors = 0
$missingRequired = @()
$missingOptional = @()

Write-Host "=== Android Reverse Engineering: Dependency Check ==="
Write-Host ""

foreach ($depId in (Get-ToolList -Want 'required')) {
    switch ($depId) {
        'java' {
            # --- Java ---
            # Resolution is delegated to Resolve-Tool; the version-parsing
            # logic below is not a resolution concern and is left exactly
            # as it was.
            $javaResolved = Resolve-Tool -Id 'java'
            if ($javaResolved) {
                $javaVersionOutput = & $javaResolved.Path -version 2>&1 | Select-Object -First 1
                $javaVersionStr = "$javaVersionOutput"
                if ($javaVersionStr -match '"(\d+)') {
                    $javaVersion = [int]$Matches[1]
                    if ($javaVersion -eq 1 -and $javaVersionStr -match '"1\.(\d+)') {
                        $javaVersion = [int]$Matches[1]
                    }
                    if ($javaVersion -ge $REQUIRED_JAVA_MAJOR) {
                        Write-Host "[OK] Java $javaVersion detected"
                    } else {
                        Write-Host "[WARN] Java detected but version $javaVersion is below $REQUIRED_JAVA_MAJOR"
                        $errors++
                        $missingRequired += "java"
                    }
                } else {
                    Write-Host "[WARN] Java detected but could not parse version from: $javaVersionStr"
                    $errors++
                    $missingRequired += "java"
                }
            } else {
                Write-Host "[MISSING] Java is not installed or not in PATH"
                $errors++
                $missingRequired += "java"
            }
        }
        'jadx' {
            # --- jadx ---
            $jadxResolved = Resolve-Tool -Id 'jadx'
            if ($jadxResolved) {
                try {
                    $jadxVersion = & $jadxResolved.Path --version 2>$null
                    Write-Host "[OK] jadx $jadxVersion detected"
                } catch {
                    Write-Host "[OK] jadx detected"
                }
            } else {
                Write-Host "[MISSING] jadx is not installed or not in PATH"
                $errors++
                $missingRequired += "jadx"
            }
        }
        default {
            # Generic fallback for a future required row tools.psv gains
            # before this script grows a dedicated case for it.
            if (Resolve-Tool -Id $depId) {
                Write-Host "[OK] $depId detected"
            } else {
                Write-Host "[MISSING] $depId is not installed or not in PATH"
                $errors++
                $missingRequired += $depId
            }
        }
    }
}

foreach ($depId in (Get-ToolList -Want 'optional')) {
    switch ($depId) {
        'vineflower' {
            # --- Vineflower ---
            # Resolve-Tool owns the resolution order (env override -> PATH
            # probe -> candidate paths); this block only figures out WHICH
            # of those three kinds of match Resolve-Tool made, so each kind
            # can keep its original wording ("<cli> CLI detected" vs "JAR
            # found: <path>").
            $ffPurpose = Get-ToolField -Id 'vineflower' -Column 'purpose'
            $ffResolved = Resolve-Tool -Id 'vineflower'
            if ($ffResolved) {
                $ffPath = $ffResolved.Path
                $ffEnvName = Get-ToolField -Id 'vineflower' -Column 'env_override'
                $ffEnvVal = $null
                if ($ffEnvName -cne '-') {
                    $ffEnvVal = [Environment]::GetEnvironmentVariable($ffEnvName)
                }
                $ffMatchedProbe = $null
                if (-not $ffEnvVal -or $ffPath -ne $ffEnvVal) {
                    $ffProbe = Get-ToolField -Id 'vineflower' -Column 'probe'
                    foreach ($p in ($ffProbe -split ',')) {
                        # @() and an inner loop for the same reason as
                        # Resolve-Tool: Get-Command returns every PATH
                        # match. Unwrapped, `$cmd.Source -eq $ffPath` on
                        # a multi-match name is an array comparison that
                        # happens to work by filtering, which is a
                        # different thing from what it looks like it
                        # says.
                        foreach ($cmd in @(Get-Command $p -CommandType Application -ErrorAction SilentlyContinue)) {
                            if ($cmd.Source -eq $ffPath) {
                                $ffMatchedProbe = $p
                                break
                            }
                        }
                        if ($ffMatchedProbe) { break }
                    }
                }
                if ($ffMatchedProbe) {
                    Write-Host "[OK] $ffMatchedProbe CLI detected"
                } else {
                    Write-Host "[OK] Vineflower JAR found: $ffPath"
                }
            } else {
                Write-Host "[MISSING] Vineflower not found (optional - $ffPurpose)"
                $missingOptional += "vineflower"
            }
        }
        'adb' {
            # --- Optional: adb ---
            if (Resolve-Tool -Id 'adb') {
                Write-Host "[OK] adb detected (optional)"
            } else {
                $adbPurpose = Get-ToolField -Id 'adb' -Column 'purpose'
                Write-Host "[MISSING] adb not found (optional - $adbPurpose)"
                $missingOptional += "adb"
            }
        }
        'python3' {
            # --- Optional: python3 (D7) ---
            # See the matching comment in check-deps.sh: recover-kotlin-
            # names.sh and lookup-name.sh are internally embedded Python,
            # but nothing declared that dependency before this row.
            # Resolve-Tool finding something named python3 proves nothing
            # by itself - on Windows, `python3` is commonly the Microsoft
            # Store's app-execution-alias stub, which resolves via PATH but
            # exits non-zero with no version output when actually run. This
            # runs the resolved interpreter rather than trusting its name.
            $py3Purpose = Get-ToolField -Id 'python3' -Column 'purpose'
            $py3Resolved = Resolve-Tool -Id 'python3'
            $py3Ok = $false
            $py3ExitCode = $null
            if ($py3Resolved) {
                try {
                    $py3CheckOutput = & $py3Resolved.Path -c "import sys; print(sys.version_info[0])" 2>$null
                    $py3ExitCode = $LASTEXITCODE
                } catch {
                    $py3CheckOutput = $null
                    $py3ExitCode = 1
                }
                if ($py3ExitCode -eq 0 -and "$py3CheckOutput".Trim() -eq '3') {
                    $py3Ok = $true
                }
            }
            if ($py3Ok) {
                $py3Full = $null
                try {
                    $py3Full = & $py3Resolved.Path -c "import platform; print(platform.python_version())" 2>$null
                } catch {
                    $py3Full = $null
                }
                if (-not "$py3Full".Trim()) { $py3Full = '3' }
                Write-Host "[OK] python3 $py3Full detected"
            } elseif ($py3Resolved) {
                Write-Host "[MISSING] python3 was found at $($py3Resolved.Path) but is not a working interpreter (exit $py3ExitCode) - optional, $py3Purpose. On Windows, a 'python3' that opens the Microsoft Store instead of running is this stub, not a real interpreter."
                $missingOptional += "python3"
            } else {
                # Resolve-Tool failing now means every name in the probe
                # list either did not exist or did not answer as Python 3
                # (the row carries verify=python3). If one of them does
                # exist, name it: telling someone "not found" when they
                # can see python3 on their own PATH sends them looking
                # for the wrong problem entirely. Mirrors check-deps.sh.
                $py3Found = $null
                $py3Probe = Get-ToolField -Id 'python3' -Column 'probe'
                if ($py3Probe -and $py3Probe -cne '-') {
                    foreach ($py3Name in ($py3Probe -split ',')) {
                        # Same Object[] trap as Resolve-Tool: Get-Command
                        # returns every PATH match, and this branch exists
                        # to name exactly one path. Left unwrapped, the
                        # message printed two paths joined by a space and
                        # the `&` below threw CommandNotFoundException,
                        # so the exit code it reports would have been the
                        # fabricated 1 from the catch rather than the
                        # interpreter's own.
                        $py3Cmd = @(Get-Command $py3Name -CommandType Application -ErrorAction SilentlyContinue) |
                            Where-Object { $_.Source } | Select-Object -First 1
                        if ($py3Cmd) { $py3Found = $py3Cmd.Source; break }
                    }
                }
                if ($py3Found) {
                    try {
                        & $py3Found -c "import sys" 2>$null | Out-Null
                        $py3FoundExit = $LASTEXITCODE
                    } catch {
                        $py3FoundExit = 1
                    }
                    Write-Host "[MISSING] python3 was found at $py3Found but is not a working interpreter (exit $py3FoundExit) - optional, $py3Purpose. On Windows, a 'python3' that opens the Microsoft Store instead of running is this stub, not a real interpreter; python.org's installer provides 'python' and never 'python3'."
                } else {
                    Write-Host "[MISSING] python3 not found (optional - $py3Purpose)"
                }
                $missingOptional += "python3"
            }
        }
        default {
            # Generic fallback for a future optional row tools.psv gains
            # before this script grows a dedicated case for it.
            if (Resolve-Tool -Id $depId) {
                Write-Host "[OK] $depId detected (optional)"
            } else {
                $depPurpose = Get-ToolField -Id $depId -Column 'purpose'
                Write-Host "[MISSING] $depId not found (optional - $depPurpose)"
                $missingOptional += $depId
            }
        }
    }
}

# --- Machine-readable summary ---
Write-Host ""
foreach ($dep in $missingRequired) {
    Write-Host "INSTALL_REQUIRED:$dep"
}
foreach ($dep in $missingOptional) {
    Write-Host "INSTALL_OPTIONAL:$dep"
}

Write-Host ""
if ($errors -gt 0) {
    Write-Host "*** $($missingRequired.Count) required dependency/ies missing. ***"
    Write-Host "Run install-dep.ps1 <name> to install, or see references/setup-guide.md."
    exit 1
} else {
    if ($missingOptional.Count -gt 0) {
        Write-Host "Required dependencies OK. $($missingOptional.Count) optional dependency/ies missing."
        Write-Host "Run install-dep.ps1 <name> to install optional tools."
    } else {
        Write-Host "All dependencies are installed. Ready to decompile."
    }
    exit 0
}
