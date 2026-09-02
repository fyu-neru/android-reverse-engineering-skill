# install-dep.ps1 — Install a single dependency for Android reverse engineering
# Usage: install-dep.ps1 <dependency>
# Dependencies: java, jadx, vineflower, adb
#
# jadx and vineflower resolve their candidate paths, GitHub repo, release
# asset filename and pinned fallback version from lib/tools.psv (via
# lib/Tools.ps1) rather than hardcoding them here — see lib/Tools.ps1's
# header comment. dex2jar and apktool are no longer installable by this
# script (2.0.0): jadx handles APK/DEX/XAPK/APKM natively, so both are now
# manual-fallback tools documented in references/setup-guide.md instead of
# dependencies with an install path.
#
# Exit codes:
#   0 — installed successfully
#   1 — installation failed (including a digest mismatch on a downloaded
#       release asset — refused, not installed)
#   2 — requires manual action (or the GitHub API and its release assets
#       are both unreachable)
param(
    [Parameter(Position=0)]
    [string]$Dep
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/Tools.ps1')

function Show-Usage {
    Write-Host @"
Usage: install-dep.ps1 <dependency>

Install a dependency required for Android reverse engineering.

Available dependencies:
  java         Java JDK 17+
  jadx         jadx decompiler
  vineflower   Vineflower (Fernflower fork) decompiler
  adb          Android Debug Bridge

The script detects available package managers (winget, scoop, choco), then:
  - Installs using the first available manager
  - Falls back to direct download to %USERPROFILE%\.local\share\
  - Prints manual instructions if no option works
"@
    exit 0
}

if (-not $Dep -or $Dep -eq '-h' -or $Dep -eq '--help') { Show-Usage }

# --- Detect environment ---
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$hasScoop  = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
$hasChoco  = [bool](Get-Command choco -ErrorAction SilentlyContinue)

function Write-Info  { param($msg) Write-Host "[INFO] $msg" }
function Write-Ok    { param($msg) Write-Host "[OK] $msg" }
function Write-Fail  { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Manual {
    param($msg)
    Write-Host "[MANUAL] $msg" -ForegroundColor Yellow
    Write-Host "         Cannot install automatically. Please install manually and retry." -ForegroundColor Yellow
    exit 2
}

# --- Helper: download a file ---
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    Write-Info "Downloading $Url..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

# --- Helper: get the latest GitHub release, tag AND all its assets'
# digests, from ONE API call — Invoke-RestMethod already parses the JSON,
# so (unlike tools.sh) no separate digest-extraction step is needed: the
# per-asset "digest" field is just $release.assets[i].digest.
function Get-GHLatestRelease {
    param([string]$Repo)
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        return Invoke-RestMethod -Uri $url -UseBasicParsing
    } catch {
        return $null
    }
}

# Confirm-Digest -Tool <id> -Path <file> -Expected <sha256:hex>
# Refuses (returns $false) on any mismatch, or if a digest could not be
# computed at all — it never falls through to "probably fine". Never call
# with an empty -Expected; the caller decides what "nothing to verify
# against" means (Get-GHReleaseDownload treats it as a manual-action case,
# not an implicit pass).
function Confirm-Digest {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = "sha256:" + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        Write-Fail "Digest mismatch for $Tool`: expected $Expected, got $actual. Refusing to install a possibly corrupted, truncated, swapped, or tampered download."
        return $false
    }
    Write-Ok "$Tool digest verified ($Expected)"
    return $true
}

# --- Helper: download a tools.psv-listed tool's GitHub release asset ---
# Get-GHReleaseDownload -Id <id> -Suffix <suffix>
# Resolves GhRepo/Asset/Pin/PinDigest for <id> from tools.psv, tries the
# live latest tag first, and falls back to the pinned version when the
# GitHub API is unreachable or rate-limited (Get-GHLatestRelease returns
# $null). Downloads the resolved asset into a fresh temp file, verifies
# its digest, and — only once that passes — returns a
# [pscustomobject]@{ Path; Version }. Mirrors tools.sh's
# gh_release_download, including its three distinct outcomes:
#   - returns $null: the download itself failed (a genuine network
#     failure). The caller's existing Write-Fail+Write-Manual (exit 2)
#     handling is untouched by this.
#   - exit 1 (from here, directly, via Confirm-Digest): the download
#     succeeded but its digest did not match — refused, not installed,
#     naming the tool and both digests. Never confused with the
#     network-failure case above.
#   - returns the downloaded file info: verified and safe to install.
function Get-GHReleaseDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Suffix
    )
    $repo = Get-ToolField -Id $Id -Column 'gh_repo'
    $assetTmpl = Get-ToolField -Id $Id -Column 'asset'
    $pin = Get-ToolField -Id $Id -Column 'pin'
    $pinDigest = Get-ToolField -Id $Id -Column 'pin_digest'

    $release = Get-GHLatestRelease -Repo $repo
    $tmp = Join-Path $env:TEMP "$Id-$([guid]::NewGuid().ToString('N'))$Suffix"

    if ($release -and $release.tag_name) {
        $tag = $release.tag_name
        $version = $tag -replace '^v', ''
        $assetName = $assetTmpl -replace '\{VERSION\}', $version
        $assetInfo = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        $expectedDigest = $null
        if ($assetInfo) { $expectedDigest = $assetInfo.digest }
        $url = "https://github.com/$repo/releases/download/$tag/$assetName"
        try {
            Invoke-Download -Url $url -Dest $tmp
        } catch {
            return $null
        }
        if (-not $expectedDigest) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Fail "GitHub's release metadata for $assetName did not include a digest to verify against."
            Write-Manual "Download and verify manually from https://github.com/$repo/releases/tag/$tag"
        }
    } else {
        Write-Info "Could not reach the GitHub API for $repo (unreachable or rate-limited); falling back to the pinned version $pin."
        $version = $pin
        $expectedDigest = $pinDigest
        $assetName = $assetTmpl -replace '\{VERSION\}', $version
        # The pinned version's tag prefix isn't recorded in tools.psv (jadx
        # tags "v1.5.6", Vineflower tags "1.12.0" — real per-project data,
        # not an installation strategy): try both conventions, the same
        # way dex2jar's pre-existing alternate-naming retry already did.
        $downloaded = $false
        foreach ($t in @("v$version", $version)) {
            $url = "https://github.com/$repo/releases/download/$t/$assetName"
            try {
                Invoke-Download -Url $url -Dest $tmp
                $downloaded = $true
                break
            } catch {
                continue
            }
        }
        if (-not $downloaded) {
            # Both tag conventions failed to download — a genuine network
            # failure (the API AND the release assets are unreachable),
            # not a digest problem. Returns $null so the caller's existing
            # Write-Fail+Write-Manual/exit-2 path handles it exactly as
            # before this task.
            return $null
        }
    }

    if (-not (Confirm-Digest -Tool $Id -Path $tmp -Expected $expectedDigest)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        exit 1
    }

    return [pscustomobject]@{ Path = $tmp; Version = $version }
}

# --- Helper: ensure directory on PATH ---
function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($currentPath -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$Dir;$currentPath", 'User')
        Write-Info "Added $Dir to user PATH. Restart your terminal to apply."
    }
    if ($env:PATH -notlike "*$Dir*") {
        $env:PATH = "$Dir;$env:PATH"
    }
}

$localBin   = Join-Path $env:USERPROFILE '.local\bin'
$localShare = Join-Path $env:USERPROFILE '.local\share'

# =====================================================================
# Dependency installers
# =====================================================================

function Install-Java {
    $javaBin = Get-Command java -ErrorAction SilentlyContinue
    if ($javaBin) {
        $verOutput = & java -version 2>&1 | Select-Object -First 1
        if ("$verOutput" -match '"(\d+)') {
            $ver = [int]$Matches[1]
            if ($ver -ge 17) {
                Write-Ok "Java $ver already installed"
                return
            }
        }
    }

    Write-Info "Installing Java JDK 17+..."
    if ($hasWinget) {
        Write-Info "Installing via winget..."
        winget install --id Microsoft.OpenJDK.17 --accept-source-agreements --accept-package-agreements
    } elseif ($hasScoop) {
        Write-Info "Installing via scoop..."
        scoop install openjdk17
    } elseif ($hasChoco) {
        Write-Info "Installing via choco..."
        choco install openjdk17 -y
    } else {
        Write-Manual "Install Java JDK 17+ from https://adoptium.net/"
    }

    # Verify
    $javaBin = Get-Command java -ErrorAction SilentlyContinue
    if ($javaBin) {
        Write-Ok "Java installed: $(& java -version 2>&1 | Select-Object -First 1)"
    } else {
        Write-Fail "Java installation may require a terminal restart for PATH update."
        exit 1
    }
}

function Install-Jadx {
    $resolved = Resolve-Tool -Id 'jadx'
    if ($resolved) {
        Write-Ok "jadx already installed: $($resolved.Path)"
        return
    }

    # Try scoop first (cleanest on Windows)
    if ($hasScoop) {
        Write-Info "Installing jadx via scoop..."
        scoop install jadx
        if (Get-Command jadx -ErrorAction SilentlyContinue) {
            Write-Ok "jadx installed via scoop"
            return
        }
    }

    # Direct download from GitHub releases. Candidate paths, gh_repo,
    # asset filename template and the pinned fallback version all come
    # from tools.psv, not hardcoded here.
    Write-Info "Installing jadx from GitHub releases..."
    $dl = Get-GHReleaseDownload -Id 'jadx' -Suffix '.zip'
    if (-not $dl) {
        Write-Fail "Could not download jadx."
        Write-Manual "Download from https://github.com/$(Get-ToolField -Id 'jadx' -Column 'gh_repo')/releases/latest"
    }
    $version = $dl.Version
    $tmpZip = $dl.Path

    $installDir = Join-Path $localShare 'jadx'
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $installDir -Force
    Remove-Item $tmpZip -Force

    # Add jadx\bin to PATH
    $jadxBin = Join-Path $installDir 'bin'
    Add-ToUserPath $jadxBin

    if (Get-Command jadx -ErrorAction SilentlyContinue) {
        Write-Ok "jadx $version installed to $installDir"
    } else {
        Write-Ok "jadx $version installed to $installDir"
        Write-Info "Restart your terminal or run: `$env:PATH = '$jadxBin;' + `$env:PATH"
    }
}

function Install-Vineflower {
    # Candidate paths, the probe list (vineflower, fernflower) and the
    # FERNFLOWER_JAR_PATH env override all come from tools.psv via
    # Resolve-Tool, not a separately-maintained candidate list.
    $resolved = Resolve-Tool -Id 'vineflower'
    if ($resolved) {
        Write-Ok "Vineflower/Fernflower already available: $($resolved.Path)"
        return
    }

    # Download JAR from GitHub releases. gh_repo, asset filename template
    # and the pinned fallback version all come from tools.psv, not
    # hardcoded here.
    Write-Info "Installing Vineflower from GitHub releases..."
    $dl = Get-GHReleaseDownload -Id 'vineflower' -Suffix '.jar'
    if (-not $dl) {
        Write-Fail "Could not download Vineflower."
        Write-Manual "Download from https://github.com/$(Get-ToolField -Id 'vineflower' -Column 'gh_repo')/releases/latest"
    }
    $version = $dl.Version
    $installDir = Join-Path $localShare 'vineflower'
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Move-Item -Path $dl.Path -Destination (Join-Path $installDir 'vineflower.jar') -Force

    # Create wrapper batch file
    New-Item -ItemType Directory -Path $localBin -Force | Out-Null
    $wrapperPath = Join-Path $localBin 'vineflower.cmd'
    Set-Content -Path $wrapperPath -Value "@echo off`r`njava -jar `"$installDir\vineflower.jar`" %*"

    Add-ToUserPath $localBin
    [Environment]::SetEnvironmentVariable('FERNFLOWER_JAR_PATH', "$installDir\vineflower.jar", 'User')
    $env:FERNFLOWER_JAR_PATH = "$installDir\vineflower.jar"

    Write-Ok "Vineflower $version installed to $installDir\vineflower.jar"
    Write-Info "FERNFLOWER_JAR_PATH set to $installDir\vineflower.jar"
}

function Install-Adb {
    if (Get-Command adb -ErrorAction SilentlyContinue) {
        Write-Ok "adb already installed"
        return
    }

    if ($hasScoop) {
        Write-Info "Installing adb via scoop..."
        scoop install adb
    } elseif ($hasChoco) {
        Write-Info "Installing adb via choco..."
        choco install adb -y
    } elseif ($hasWinget) {
        Write-Info "Installing via winget..."
        winget install Google.PlatformTools --accept-source-agreements --accept-package-agreements
    } else {
        Write-Manual "Install Android SDK Platform Tools from https://developer.android.com/tools/releases/platform-tools"
    }

    if (Get-Command adb -ErrorAction SilentlyContinue) {
        Write-Ok "adb installed"
    } else {
        Write-Fail "adb installation may have failed."
        exit 1
    }
}

# =====================================================================
# Dispatch
# =====================================================================

switch ($Dep) {
    'java'        { Install-Java }
    'jadx'        { Install-Jadx }
    'vineflower'  { Install-Vineflower }
    'fernflower'  { Install-Vineflower }
    'adb'         { Install-Adb }
    default {
        Write-Host "Error: Unknown dependency '$Dep'" -ForegroundColor Red
        Write-Host "Available: java, jadx, vineflower, adb"
        exit 1
    }
}
