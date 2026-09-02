# check-deps.ps1 — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL_REQUIRED/INSTALL_OPTIONAL lines.
#
# Existence and resolution order (env override -> PATH probe -> candidate
# paths) for the tools listed in lib/tools.psv (java, jadx, vineflower, adb)
# comes from lib/Tools.ps1's Get-ToolList/Resolve-Tool/Get-ToolField rather
# than a second, independently-maintained candidate-path list. dex2jar and
# apktool are not yet in tools.psv (they are dropped from the plugin
# entirely in a later 2.0.0 task) and keep their original hardcoded checks,
# unchanged, in their original output position.
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
            # --- Fernflower / Vineflower ---
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
                        $cmd = Get-Command $p -CommandType Application -ErrorAction SilentlyContinue
                        if ($cmd -and $cmd.Source -eq $ffPath) {
                            $ffMatchedProbe = $p
                            break
                        }
                    }
                }
                if ($ffMatchedProbe) {
                    Write-Host "[OK] $ffMatchedProbe CLI detected"
                } else {
                    Write-Host "[OK] Fernflower/Vineflower JAR found: $ffPath"
                }
            } else {
                Write-Host "[MISSING] Fernflower/Vineflower not found (optional - $ffPurpose)"
                $missingOptional += "vineflower"
            }

            # --- dex2jar ---
            # Not yet in tools.psv (dropped from the plugin entirely in a
            # later 2.0.0 task); kept hardcoded here, in its original
            # output position between vineflower and apktool.
            $d2jBin = Get-Command d2j-dex2jar -ErrorAction SilentlyContinue
            if (-not $d2jBin) {
                $d2jBin = Get-Command d2j-dex2jar.bat -ErrorAction SilentlyContinue
            }
            if ($d2jBin) {
                Write-Host "[OK] dex2jar detected"
            } else {
                Write-Host "[MISSING] dex2jar not found (optional - needed to use Fernflower on APK/DEX files)"
                $missingOptional += "dex2jar"
            }

            # --- Optional: apktool ---
            # Not yet in tools.psv (dropped from the plugin entirely in a
            # later 2.0.0 task); kept hardcoded here, in its original
            # output position.
            if (Get-Command apktool -ErrorAction SilentlyContinue) {
                Write-Host "[OK] apktool detected (optional)"
            } else {
                Write-Host "[MISSING] apktool not found (optional - useful for resource decoding)"
                $missingOptional += "apktool"
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
