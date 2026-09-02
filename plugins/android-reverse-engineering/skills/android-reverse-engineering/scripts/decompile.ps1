# decompile.ps1 — Decompile APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR/CLASS using jadx, fernflower, or both
param(
    [Alias('o')]
    [string]$Output,
    [switch]$Deobf,
    [switch]$NoRes,
    [string]$Engine = 'jadx',
    [Parameter(Position=0)]
    [string]$InputFile,
    [Alias('h')]
    [switch]$Help
)

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

function Show-Usage {
    Write-Host @"
Usage: decompile.ps1 [OPTIONS] <file>

Decompile an Android package or bytecode archive.

Arguments:
  <file>            Path to a .apk, .xapk, .apkm, .apks, .aab, .dex, .zip,
                    .jar, .aar, or .class file

Options:
  -Output DIR       Output directory (default: <filename>-decompiled)
  -Deobf            Enable deobfuscation of names
  -NoRes            Skip resource decoding (faster, code-only)
  -Engine ENGINE    Decompiler engine: jadx, fernflower, or both (default: jadx)
  -Help             Show this help message

Engines:
  jadx        Use jadx (default). Handles APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR
              natively (including split bundles) and decodes resources.
  fernflower  Use Fernflower/Vineflower. Better on complex Java, lambdas, generics.
              Only accepts .jar, .aar, and .class input - it decompiles JVM
              bytecode, not DEX, and dex2jar is no longer part of this pipeline.
              Use -Engine jadx for anything else.
  both        Run both decompilers side by side for comparison.
              jadx output  -> <output>/jadx/
              fernflower   -> <output>/fernflower/
              (requires a .jar, .aar, or .class input, same as -Engine fernflower)

Environment:
  FERNFLOWER_JAR_PATH   Path to fernflower.jar or vineflower.jar

Examples:
  .\decompile.ps1 app-release.apk
  .\decompile.ps1 app-bundle.xapk
  .\decompile.ps1 -Engine both -Deobf library.jar
  .\decompile.ps1 -Engine fernflower library.jar
"@
    exit 0
}

if ($Help) { Show-Usage }

# --- Validate input ---
if (-not $InputFile) {
    Write-Host "Error: No input file specified." -ForegroundColor Red
    Show-Usage
}

if (-not (Test-Path $InputFile)) {
    Write-Host "Error: File not found: $InputFile" -ForegroundColor Red
    exit 1
}

$extLower = [IO.Path]::GetExtension($InputFile).TrimStart('.').ToLower()
if ($extLower -notin @('apk', 'xapk', 'apkm', 'apks', 'aab', 'dex', 'zip', 'jar', 'aar', 'class')) {
    Write-Host "Error: Unsupported file type '.$extLower'. Expected one of: apk, xapk, apkm, apks, aab, dex, zip, jar, aar, class" -ForegroundColor Red
    exit 1
}

if ($Engine -notin @('jadx', 'fernflower', 'both')) {
    Write-Host "Error: Unknown engine '$Engine'. Use jadx, fernflower, or both." -ForegroundColor Red
    exit 1
}

$baseName = [IO.Path]::GetFileNameWithoutExtension($InputFile)
$inputFileAbs = (Resolve-Path $InputFile).Path

if (-not $Output) {
    $Output = "$baseName-decompiled"
}

# --- jadx decompilation ---
function Invoke-Jadx {
    param([string]$OutDir, [string]$FileAbs, [string]$FileExt)

    if (-not (Get-Command jadx -ErrorAction SilentlyContinue)) {
        Write-Host "Error: jadx is not installed or not in PATH." -ForegroundColor Red
        return $false
    }

    $jadxArgs = @('-d', $OutDir)
    if ($Deobf) { $jadxArgs += '--deobf' }
    if ($NoRes) { $jadxArgs += '--no-res' }
    $jadxArgs += '--show-bad-code'
    $jadxArgs += $FileAbs

    Write-Host "Running: jadx $($jadxArgs -join ' ')"
    & jadx @jadxArgs

    $sourcesDir = Join-Path $OutDir 'sources'
    if (Test-Path $sourcesDir) {
        $count = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java').Count
        Write-Host "jadx output: $sourcesDir\"
        Write-Host "Java files decompiled by jadx: $count"
    }
    return $true
}

# --- Fernflower decompilation ---
function Invoke-Fernflower {
    param([string]$OutDir, [string]$FileAbs, [string]$FileExt)

    # dex2jar has been removed from this pipeline (2.0.0): converting DEX to
    # JVM bytecode first threw away exactly the metadata (lambdas, generic
    # signatures, records, switch-on-string) that made Fernflower/Vineflower
    # worth running in the first place, and jadx reads DEX directly and
    # better. So this engine now only ever runs on real JVM bytecode.
    if ($FileExt -notin @('jar', 'aar', 'class')) {
        Write-Host "Error: The fernflower/vineflower engine only decompiles .jar, .aar, and .class files." -ForegroundColor Red
        Write-Host "Got '.$FileExt'. dex2jar conversion has been removed - jadx reads DEX/APK-family files natively and produces better results."
        Write-Host "Use -Engine jadx for .apk, .xapk, .apkm, .apks, .aab, .dex, and .zip files."
        return $false
    }

    $ffCmd = Resolve-Tool -Id 'vineflower'
    if (-not $ffCmd) {
        Write-Host "Error: Fernflower/Vineflower not found." -ForegroundColor Red
        Write-Host "Set FERNFLOWER_JAR_PATH or see references/setup-guide.md"
        return $false
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $jarToDecompile = $FileAbs

    # Build fernflower args
    $ffArgs = @('-dgs=1', '-mpm=60')
    if ($Deobf) { $ffArgs += '-ren=1' }
    $ffArgs += $jarToDecompile
    $ffArgs += $OutDir

    if ($ffCmd.Kind -eq 'cli') {
        Write-Host "Running: $($ffCmd.Path) $($ffArgs -join ' ')"
        & $ffCmd.Path @ffArgs
    } else {
        Write-Host "Running: java -jar $($ffCmd.Path) $($ffArgs -join ' ')"
        & java -jar $ffCmd.Path @ffArgs
    }

    # Fernflower outputs a JAR containing .java files — extract it
    $resultJar = Join-Path $OutDir ([IO.Path]::GetFileName($jarToDecompile))
    if (Test-Path $resultJar) {
        $sourcesDir = Join-Path $OutDir 'sources'
        New-Item -ItemType Directory -Path $sourcesDir -Force | Out-Null
        Expand-Archive -Path $resultJar -DestinationPath $sourcesDir -Force
        Remove-Item $resultJar -Force
        $count = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java').Count
        Write-Host "Fernflower output: $sourcesDir\"
        Write-Host "Java files decompiled by Fernflower: $count"
    }

    return $true
}

# --- Summary helper ---
function Show-Structure {
    param([string]$SrcDir, [string]$Label)
    if (Test-Path $SrcDir) {
        Write-Host ""
        Write-Host "Top-level packages ($Label):"
        $packages = Get-ChildItem -Path $SrcDir -Directory -Recurse -Depth 2 |
            ForEach-Object { $_.FullName.Replace("$SrcDir\", '') } |
            Sort-Object

        $total = $packages.Count
        if ($total -eq 0) {
            Write-Host "(none)"
            return
        }

        # Obfuscated APKs commonly rename every top-level package to a
        # single letter (a/, b/, c/, ...). A flat positional cap can fill
        # up entirely on that noise before a real package like com/ -
        # which sorts after two dozen+ single-letter names - is ever
        # reached. List multi-character top-level packages first so a
        # real package name can never be crowded out, then fill any
        # remaining slots with the single-letter entries.
        $cap = 20
        $named = @($packages | Where-Object { ($_ -split '\\')[0].Length -gt 1 })
        $single = @($packages | Where-Object { ($_ -split '\\')[0].Length -eq 1 })
        $ordered = @($named) + @($single)

        $ordered | Select-Object -First $cap

        if ($total -gt $cap) {
            Write-Host "... and $($total - $cap) more (showing $cap of $total; single-letter package dirs are listed last)"
        }
    }
}

# --- Decompile a single file ---
function Invoke-DecompileSingle {
    param([string]$FileAbs, [string]$OutDir, [string]$Label)

    $fileExt = [IO.Path]::GetExtension($FileAbs).TrimStart('.').ToLower()

    if ($Label) {
        Write-Host "=== Decompiling $Label (engine: $Engine) ==="
    }

    switch ($Engine) {
        'jadx' {
            Invoke-Jadx -OutDir $OutDir -FileAbs $FileAbs -FileExt $fileExt
            Show-Structure (Join-Path $OutDir 'sources') 'jadx'
        }
        'fernflower' {
            Invoke-Fernflower -OutDir $OutDir -FileAbs $FileAbs -FileExt $fileExt
            Show-Structure (Join-Path $OutDir 'sources') 'fernflower'
        }
        'both' {
            Write-Host "--- Pass 1: jadx ---"
            Invoke-Jadx -OutDir (Join-Path $OutDir 'jadx') -FileAbs $FileAbs -FileExt $fileExt
            Write-Host ""
            Write-Host "--- Pass 2: Fernflower ---"
            Invoke-Fernflower -OutDir (Join-Path $OutDir 'fernflower') -FileAbs $FileAbs -FileExt $fileExt

            Show-Structure (Join-Path $OutDir 'jadx\sources') 'jadx'
            Show-Structure (Join-Path $OutDir 'fernflower\sources') 'fernflower'

            Write-Host ""
            Write-Host "=== Comparison ==="
            $jadxCount = 0; $ffCount = 0
            $jadxSources = Join-Path $OutDir 'jadx\sources'
            $ffSources   = Join-Path $OutDir 'fernflower\sources'
            if (Test-Path $jadxSources) {
                $jadxCount = (Get-ChildItem -Path $jadxSources -Recurse -Filter '*.java').Count
            }
            if (Test-Path $ffSources) {
                $ffCount = (Get-ChildItem -Path $ffSources -Recurse -Filter '*.java').Count
            }
            Write-Host "jadx:        $jadxCount Java files"
            Write-Host "Fernflower:  $ffCount Java files"

            if (Test-Path $jadxSources) {
                $jadxErrors = (Get-ChildItem -Path $jadxSources -Recurse -Filter '*.java' -File |
                    Select-String -Pattern 'JADX WARNING|JADX WARN|JADX ERROR|Code decompiled incorrectly' -SimpleMatch -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Path -Unique).Count
                Write-Host "jadx files with warnings/errors: $jadxErrors"
            }
            Write-Host ""
            Write-Host "Tip: compare specific classes between jadx/ and fernflower/ to pick the better output."
        }
    }
}

# --- Run ---
Write-Host "=== Decompiling $InputFile (engine: $Engine) ==="
Write-Host "Output directory: $Output"
Write-Host ""

# XAPK/APKM/APKS/AAB/DEX/ZIP files are handed to jadx directly (no
# hand-rolled extraction step): jadx natively understands these formats,
# extracts and decompiles every contained APK/DEX into one merged source
# tree, and does it without the config-split blindness the old per-APK
# loop here had.
#
# Two capabilities are lost as a result, and are not silently
# reintroduced: jadx does not copy the XAPK's manifest.json into its
# output, and it does not enumerate OBB files. Both are recorded in
# SKILL.md. The output layout also changes: previously each contained APK
# got its own subdirectory under $Output; jadx now merges everything into
# a single tree, same as it always has for a plain .apk.
Invoke-DecompileSingle -FileAbs $inputFileAbs -OutDir $Output -Label ''

# --- Split/bundled APK detection ---
# Some APKs are bundles: the outer APK contains
# base.apk + split_config.*.apk inside the resources directory. jadx will
# decompile the thin outer wrapper and produce very few Java files.
# Detect this and automatically decompile the inner base.apk.
$sourcesDir = Join-Path $Output 'sources'
$resourcesDir = Join-Path $Output 'resources'
if ((Test-Path $sourcesDir) -and (Test-Path $resourcesDir)) {
    $javaCount = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java' -File -ErrorAction SilentlyContinue).Count
    $innerApks = Get-ChildItem -Path $resourcesDir -Filter '*.apk' -File -ErrorAction SilentlyContinue
    $baseApk = $innerApks | Where-Object { $_.Name -eq 'base.apk' }

    if ($javaCount -le 10 -and $baseApk) {
        Write-Host ""
        Write-Host "=== Split/bundled APK detected ==="
        Write-Host "Outer APK produced only $javaCount Java file(s) but contains $($innerApks.Count) inner APK(s):"
        foreach ($inner in $innerApks) {
            Write-Host "  - $($inner.Name)"
        }
        Write-Host ""
        Write-Host "Decompiling base.apk (contains the actual app code)..."
        $baseOutput = Join-Path $Output 'base'
        Invoke-DecompileSingle -FileAbs $baseApk.FullName -OutDir $baseOutput -Label 'base.apk'

        # Decompile any split APKs that aren't just config splits
        $splitApks = $innerApks | Where-Object { $_.Name -ne 'base.apk' -and $_.Name -notmatch 'split_config\.' }
        foreach ($split in $splitApks) {
            $splitName = [IO.Path]::GetFileNameWithoutExtension($split.Name)
            Write-Host ""
            Write-Host "Decompiling $($split.Name)..."
            Invoke-DecompileSingle -FileAbs $split.FullName -OutDir (Join-Path $Output $splitName) -Label $split.Name
        }

        if ($innerApks | Where-Object { $_.Name -match 'split_config\.' }) {
            Write-Host ""
            Write-Host "Skipped config splits (resource/ABI only):"
            $innerApks | Where-Object { $_.Name -match 'split_config\.' } | ForEach-Object { Write-Host "  - $($_.Name)" }
        }

        Write-Host ""
        Write-Host "NOTE: The main decompiled source is in: $(Join-Path $Output 'base\sources')"
    }
}

Write-Host ""
Write-Host "=== Decompilation complete ==="
