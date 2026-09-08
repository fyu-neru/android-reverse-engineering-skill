# decompile.ps1 — Decompile APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR/CLASS using jadx, vineflower, or both
param(
    [Alias('o')]
    [string]$Output,
    [switch]$Deobf,
    [switch]$NoRes,
    [string]$Engine = 'jadx',
    [string]$Mode = '',
    [Parameter(Position=0)]
    [string]$InputFile,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Ensure Write-Host output round-trips correctly when this script's stdout
# is redirected to a file rather than a real console: the migration-hint
# messages below contain non-ASCII text, and some Windows console code
# pages otherwise re-encode it lossily on the way out.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
  -Engine ENGINE    Decompiler engine: jadx, vineflower, or both (default: jadx)
  -Mode MODE        jadx decompilation mode: auto, restructure, simple, or
                     fallback. Passed through to jadx as -m. When omitted,
                     nothing is passed and jadx uses its own default (auto).
  -Help             Show this help message

Engines:
  jadx        Use jadx (default). Handles APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR
              natively (including split bundles) and decodes resources.
  vineflower  Use Vineflower. Better on complex Java, lambdas, generics.
              Only accepts .jar, .aar, and .class input - it decompiles JVM
              bytecode, not DEX, and dex2jar is no longer part of this pipeline.
              Use -Engine jadx for anything else.
  both        Run both decompilers side by side for comparison.
              jadx output  -> <output>/jadx/
              vineflower   -> <output>/vineflower/
              (requires a .jar, .aar, or .class input, same as -Engine vineflower)

jadx modes (-Mode, jadx engine only):
  auto         jadx picks the best strategy per method. This is jadx's own
               default - it is never passed explicitly by this script unless
               you type -Mode auto yourself.
  restructure  Force the normal CFG-restructuring decompiler.
  simple       A simpler, more literal bytecode-to-source translation.
  fallback     Escape hatch for a class jadx crashes on or decompiles into
               obviously broken output - bypasses the normal decompiler for
               it. Produces less readable code; use only when needed.

Environment:
  VINEFLOWER_JAR   Path to vineflower.jar

Examples:
  .\decompile.ps1 app-release.apk
  .\decompile.ps1 app-bundle.xapk
  .\decompile.ps1 -Engine both -Deobf library.jar
  .\decompile.ps1 -Engine vineflower library.jar
"@
    exit 0
}

if ($Help) { Show-Usage }

# Task 8 (2.0.0) renamed this engine's flag value and env var. Neither
# check below is a compatibility shim — both still refuse to run. They
# only replace a generic "Unknown option"/silent-ignore outcome with a
# message naming the new spelling, so a user hitting either one has
# something to act on.
if ($Engine -eq 'fernflower') {
    Write-Host "Error: --engine fernflower 已於 2.0.0 更名為 --engine vineflower" -ForegroundColor Red
    exit 1
}
if ($env:FERNFLOWER_JAR_PATH) {
    Write-Host "Error: FERNFLOWER_JAR_PATH 已於 2.0.0 更名為 VINEFLOWER_JAR" -ForegroundColor Red
    exit 1
}

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

if ($Engine -notin @('jadx', 'vineflower', 'both')) {
    Write-Host "Error: Unknown engine '$Engine'. Use jadx, vineflower, or both." -ForegroundColor Red
    exit 1
}

# An empty $Mode (its default) is deliberately accepted here - it means
# -Mode was never given. Invoke-Jadx below only appends -m when $Mode is
# non-empty, so jadx keeps its own default rather than this script
# hardcoding one on jadx's behalf.
if ($Mode -and ($Mode -notin @('auto', 'restructure', 'simple', 'fallback'))) {
    Write-Host "Error: Unknown mode '$Mode'. Use auto, restructure, simple, or fallback." -ForegroundColor Red
    exit 1
}

$baseName = [IO.Path]::GetFileNameWithoutExtension($InputFile)
$inputFileAbs = (Resolve-Path $InputFile).Path

if (-not $Output) {
    $Output = "$baseName-decompiled"
}

# --- jadx decompilation ---
# Returns an integer status mirroring decompile.sh's run_jadx: 0 (clean
# success), 1 (hard failure - no Java output), 2 (jadx exited non-zero but
# still produced usable output - partial success). Before the C2 fix this
# function returned a bare $true whenever jadx was merely FOUND, regardless
# of $LASTEXITCODE or whether it wrote anything at all - a failed
# decompile still reported success and the caller still printed
# "=== Decompilation complete ===".
function Invoke-Jadx {
    param([string]$OutDir, [string]$FileAbs, [string]$FileExt)

    # Resolved via Resolve-Tool (env override -> PATH probe -> tools.psv
    # candidates), the same resolution order check-deps.ps1 reports
    # against. A bare Get-Command here would miss a jadx that
    # install-dep.ps1 just placed at one of tools.psv's candidate paths -
    # exactly the install-then-can't-find-it divergence between
    # check-deps and decompile this resolution layer exists to eliminate.
    $jadxCmd = Resolve-Tool -Id 'jadx'
    if (-not $jadxCmd) {
        Write-Host "Error: jadx is not installed or not in PATH." -ForegroundColor Red
        return 1
    }

    $jadxArgs = @('-d', $OutDir)
    if ($Deobf) { $jadxArgs += '--deobf' }
    if ($NoRes) { $jadxArgs += '--no-res' }
    # -m is only appended when -Mode was actually given ($Mode non-empty).
    # Hardcoding "-m auto" here would silently diverge the moment jadx
    # changes what its own default means - letting jadx decide is the
    # whole point. $Mode is read from script scope (set by the -Mode
    # parameter), the same way $Deobf/$NoRes already are above.
    if ($Mode) { $jadxArgs += '-m'; $jadxArgs += $Mode }
    $jadxArgs += '--show-bad-code'
    $jadxArgs += $FileAbs

    Write-Host "Running: $($jadxCmd.Path) $($jadxArgs -join ' ')"
    # Piped through Out-Host rather than left as a bare native-command
    # call: Invoke-DecompileSingle's caller now captures ITS return value
    # (the C1 fix), and PowerShell folds an unconsumed native command's
    # stdout into the enclosing function's own return value right
    # alongside that boolean - which would silently swallow every line of
    # real jadx output into $decompileOk instead of ever reaching the
    # console.
    & $jadxCmd.Path @jadxArgs | Out-Host
    # The C2 fix: read jadx's own exit code. Piping to a cmdlet (Out-Host)
    # does not clear $LASTEXITCODE - it still reflects the native
    # executable's own status right after the pipeline statement runs.
    $jadxExit = $LASTEXITCODE
    if ($null -eq $jadxExit) { $jadxExit = 0 }

    $sourcesDir = Join-Path $OutDir 'sources'
    $count = 0
    Write-Host "jadx output: $sourcesDir\"
    if (Test-Path $sourcesDir) {
        $count = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java').Count
        Write-Host "Java files decompiled by jadx: $count"
    }

    if ($jadxExit -eq 0) { return 0 }

    if ($count -gt 0) {
        Write-Host "Warning: jadx exited with status $jadxExit after writing $count Java files; treating this as partial success." -ForegroundColor Yellow
        return 2
    }

    Write-Host "Error: jadx failed with status $jadxExit and produced no Java output." -ForegroundColor Red
    return 1
}

# --- Vineflower decompilation ---
# Returns an integer status with the same 0/1/2 meaning as Invoke-Jadx
# above (mirrors decompile.sh's run_vineflower). Before the C2 fix this
# always returned $true once Vineflower was found, even when no result jar
# appeared and zero .java files were ever written.
function Invoke-Vineflower {
    param([string]$OutDir, [string]$FileAbs, [string]$FileExt)

    # dex2jar has been removed from this pipeline (2.0.0): converting DEX to
    # JVM bytecode first threw away exactly the metadata (lambdas, generic
    # signatures, records, switch-on-string) that made Vineflower worth
    # running in the first place, and jadx reads DEX directly and better.
    # So this engine now only ever runs on real JVM bytecode.
    if ($FileExt -notin @('jar', 'aar', 'class')) {
        Write-Host "Error: The vineflower engine only decompiles .jar, .aar, and .class files." -ForegroundColor Red
        Write-Host "Got '.$FileExt'. dex2jar conversion has been removed - jadx reads DEX/APK-family files natively and produces better results."
        Write-Host "Use -Engine jadx for .apk, .xapk, .apkm, .apks, .aab, .dex, and .zip files."
        return 1
    }

    # The C1 fix: Get-ToolArgv (Tools.ps1) resolves the full invocation,
    # including java for a kind=jar tool via Resolve-Tool -Id 'java' -
    # mirroring tools.sh's tool_argv, which decompile.sh already used
    # here. Before this, the kind=jar branch below called the bare `java`
    # command directly, ignoring JAVA_BIN and every tools.psv candidate
    # entirely - the exact check-deps-says-yes/decompile-says-no
    # divergence this release exists to eliminate.
    $vfArgv = Get-ToolArgv -Id 'vineflower'
    if (-not $vfArgv) {
        Write-Host "Error: Vineflower not found." -ForegroundColor Red
        Write-Host "Set VINEFLOWER_JAR or see references/setup-guide.md"
        return 1
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $jarToDecompile = $FileAbs

    # Build vineflower args
    $ffArgs = @('-dgs=1', '-mpm=60')
    if ($Deobf) { $ffArgs += '-ren=1' }
    $ffArgs += $jarToDecompile
    $ffArgs += $OutDir

    $vfExe = $vfArgv[0]
    $vfBaseArgs = @()
    if ($vfArgv.Length -gt 1) { $vfBaseArgs = @($vfArgv[1..($vfArgv.Length - 1)]) }
    $fullArgs = @($vfBaseArgs) + $ffArgs

    # Piped through Out-Host for the same reason as the jadx invocation
    # above: Invoke-DecompileSingle's caller now captures ITS return
    # value, and a bare native-command call here would have Vineflower's
    # console output silently folded into that captured boolean instead
    # of ever being displayed.
    Write-Host "Running: $($vfArgv -join ' ') $($ffArgs -join ' ')"

    # Cross-platform-divergence fix (pre-2.0.0): decompile.sh has wrapped
    # this invocation in `timeout $VINEFLOWER_TIMEOUT_SECONDS` since before
    # this release, so a hung Vineflower dies on bash. decompile.ps1 had no
    # counterpart at all - a hang here ran forever on Windows while the
    # same documented env var silently did nothing. Same default (900),
    # same env var name, same validation, same message text as bash's
    # `[[ "$ff_timeout_seconds" =~ ^[0-9]+$ ]] && (( ff_timeout_seconds >
    # 0 ))` guard.
    $ffTimeoutSeconds = $env:VINEFLOWER_TIMEOUT_SECONDS
    if ([string]::IsNullOrEmpty($ffTimeoutSeconds)) { $ffTimeoutSeconds = '900' }
    $ffUseTimeout = ($ffTimeoutSeconds -match '^[0-9]+$') -and ([int]$ffTimeoutSeconds -gt 0)

    if ($ffUseTimeout) {
        Write-Host "Vineflower timeout: ${ffTimeoutSeconds}s (override with VINEFLOWER_TIMEOUT_SECONDS)"

        # Wait-Process -Timeout alone does not terminate the process on
        # timeout - it just stops waiting and returns, leaving Vineflower
        # (and, via a wrapper, its own java child) running as an orphan.
        # Start-Process -PassThru plus WaitForExit(ms) lets us actually
        # kill the process tree when the wait expires, mirroring what
        # bash's `timeout` does with SIGTERM/SIGKILL.
        #
        # Start-Process (UseShellExecute=$false, forced by -NoNewWindow)
        # calls CreateProcess directly, which - unlike the call operator
        # a few lines below, or a real ShellExecute - cannot launch a
        # .cmd/.bat file itself; only cmd.exe can interpret one. JAVA_BIN
        # (or a future tools.psv candidate) resolving to a wrapper script
        # is exactly this case, so route through cmd.exe /c when $vfExe
        # is one.
        $ffLaunchFile = $vfExe
        $ffLaunchArgs = $fullArgs
        if ($vfExe -match '\.(cmd|bat)$') {
            $ffLaunchFile = 'cmd.exe'
            $ffLaunchArgs = @('/c', $vfExe) + $fullArgs
        }
        # Start-Process defaults -WorkingDirectory to the launched file's own
        # directory, not the caller's - unlike the call operator used below,
        # which inherits $PWD. $OutDir/$jarToDecompile are frequently
        # relative (the default $Output is), so without this override the
        # timed invocation would resolve them against the wrong directory.
        $ffProc = Start-Process -FilePath $ffLaunchFile -ArgumentList $ffLaunchArgs -NoNewWindow -PassThru -WorkingDirectory (Get-Location).Path
        if (-not $ffProc.WaitForExit([int]$ffTimeoutSeconds * 1000)) {
            # Kill the whole process tree, not just $ffProc itself, in case
            # the resolved tool is a wrapper (e.g. a .cmd) around a real
            # java child. taskkill /T walks the tree; /F forces termination.
            & taskkill.exe /PID $ffProc.Id /T /F *> $null
            $ffProc.WaitForExit()
            # The real exit status here is "timed out", not whatever
            # taskkill's forced termination happens to leave in
            # $ffProc.ExitCode - mirror bash's `timeout`, which reports 124
            # on timeout regardless of the killed process's own exit code.
            # decompile.sh already special-cases 124 below (kept as-is).
            $ffExit = 124
        } else {
            $ffExit = $ffProc.ExitCode
        }
    } else {
        & $vfExe @fullArgs | Out-Host
        # The C2 fix: see the matching comment in Invoke-Jadx above.
        $ffExit = $LASTEXITCODE
        if ($null -eq $ffExit) { $ffExit = 0 }
    }

    # Vineflower outputs a JAR containing .java files — extract it
    $resultJar = Join-Path $OutDir ([IO.Path]::GetFileName($jarToDecompile))
    $sourcesDir = Join-Path $OutDir 'sources'
    if (Test-Path $resultJar) {
        New-Item -ItemType Directory -Path $sourcesDir -Force | Out-Null
        Expand-Archive -Path $resultJar -DestinationPath $sourcesDir -Force
        Remove-Item $resultJar -Force
    }

    New-Item -ItemType Directory -Path $sourcesDir -Force | Out-Null
    $count = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java' -ErrorAction SilentlyContinue).Count

    # Vineflower may write sources directly into the destination folder
    # tree instead of a result jar. Mirrors decompile.sh's direct-folder-
    # output fallback, which had no PowerShell counterpart before this fix.
    if ($count -eq 0) {
        $directEntries = @(Get-ChildItem -Path $OutDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'sources' })
        $directCount = 0
        foreach ($entry in $directEntries) {
            if ($entry.PSIsContainer) {
                $directCount += (Get-ChildItem -Path $entry.FullName -Recurse -Filter '*.java' -ErrorAction SilentlyContinue).Count
            } elseif ($entry.Extension -eq '.java') {
                $directCount += 1
            }
        }
        if ($directCount -gt 0) {
            foreach ($entry in $directEntries) {
                Move-Item -Path $entry.FullName -Destination $sourcesDir -Force
            }
            $count = (Get-ChildItem -Path $sourcesDir -Recurse -Filter '*.java' -ErrorAction SilentlyContinue).Count
        }
    }

    if ($count -gt 0) {
        Write-Host "Vineflower output: $sourcesDir\"
        Write-Host "Java files decompiled by Vineflower: $count"
        if ($ffExit -ne 0) {
            Write-Host "Warning: Vineflower exited with status $ffExit after writing $count Java files; treating this as partial success." -ForegroundColor Yellow
            return 2
        }
        return 0
    }

    Write-Host "Error: Vineflower produced no Java output." -ForegroundColor Red
    if ($ffExit -ne 0) {
        if ($ffExit -eq 124) {
            Write-Host "Error: Vineflower exceeded timeout (${ffTimeoutSeconds}s)." -ForegroundColor Red
        }
        Write-Host "Error: Vineflower exited with status $ffExit." -ForegroundColor Red
    }
    return 1
}

# --- Summary helper ---
function Show-Structure {
    param([string]$SrcDir, [string]$Label)
    if (Test-Path $SrcDir) {
        # $SrcDir arrives relative in the common case ($Output defaults to
        # a relative "<name>-decompiled"). Resolve it to an absolute path
        # BEFORE stripping it as a prefix below: comparing a relative
        # $SrcDir against Get-ChildItem's always-absolute .FullName never
        # matches, so the prefix strip silently no-ops, every entry keeps
        # its full "C:\...\<name>-decompiled\sources\..." path, and
        # ($_ -split '\\')[0] evaluates to "C:" for every single entry -
        # collapsing the single-letter-vs-named split below into one
        # bucket and making the crowding-out fix inert on the path users
        # actually take.
        $srcDirAbs = (Resolve-Path -LiteralPath $SrcDir).Path
        Write-Host ""
        Write-Host "Top-level packages ($Label):"
        $packages = Get-ChildItem -Path $srcDirAbs -Directory -Recurse -Depth 2 |
            ForEach-Object { $_.FullName.Replace("$srcDirAbs\", '') } |
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

        # Write-Host explicitly rather than letting these objects fall
        # through to the success/output stream: Invoke-DecompileSingle's
        # caller now captures ITS return value (the C1 fix), and a bare
        # pipeline emission here would be swept into that capture right
        # alongside the boolean, silently disappearing from the console
        # instead of ever being displayed.
        $ordered | Select-Object -First $cap | ForEach-Object { Write-Host $_ }

        if ($total -gt $cap) {
            Write-Host "... and $($total - $cap) more (showing $cap of $total; single-letter package dirs are listed last)"
        }
    }
}

# --- Decompile a single file ---
# Returns $true on overall success (including a partial-success engine
# status of 2 - a warning, not a failure) and $false only on a hard engine
# failure (status 1). Mirrors decompile.sh's decompile_single, whose only
# externally-visible failure signal is the same: a hard per-engine status
# of 1 stops the run; a 2 is logged and treated as success.
function Invoke-DecompileSingle {
    param([string]$FileAbs, [string]$OutDir, [string]$Label)

    $fileExt = [IO.Path]::GetExtension($FileAbs).TrimStart('.').ToLower()

    if ($Label) {
        Write-Host "=== Decompiling $Label (engine: $Engine) ==="
    }

    # Each engine function now returns an integer status - 0 (success), 1
    # (hard failure), 2 (partial success with warnings) - captured into a
    # variable rather than left as a bare statement. In PowerShell, a
    # function's return value that is neither captured nor piped becomes
    # part of the CALLER's own output stream - so an uncaptured return
    # here doesn't just vanish, it surfaces as a stray integer line on
    # stdout (via this function's own uncaptured return) AND is
    # unavailable for deciding whether decompilation actually succeeded.
    # That was harmless while nothing downstream checked it; it became
    # load-bearing once the vineflower engine started refusing input (the
    # original C1 fix) and, now, once a failed engine run needed its exit
    # code checked too (the C2 fix).
    $engineOk = $true

    switch ($Engine) {
        'jadx' {
            $jadxStatus = Invoke-Jadx -OutDir $OutDir -FileAbs $FileAbs -FileExt $fileExt
            Show-Structure (Join-Path $OutDir 'sources') 'jadx'
            if ($jadxStatus -eq 1) { return $false }
            if ($jadxStatus -eq 2) {
                Write-Host "jadx completed with warnings but produced usable output."
            }
        }
        'vineflower' {
            $ffStatus = Invoke-Vineflower -OutDir $OutDir -FileAbs $FileAbs -FileExt $fileExt
            Show-Structure (Join-Path $OutDir 'sources') 'vineflower'
            if ($ffStatus -eq 1) { return $false }
            if ($ffStatus -eq 2) {
                Write-Host "Vineflower completed with warnings but produced usable output."
            }
        }
        'both' {
            Write-Host "--- Pass 1: jadx ---"
            $jadxStatus = Invoke-Jadx -OutDir (Join-Path $OutDir 'jadx') -FileAbs $FileAbs -FileExt $fileExt
            if ($jadxStatus -eq 1) { return $false }
            if ($jadxStatus -eq 2) {
                Write-Host "Continuing to Vineflower because jadx produced usable output despite warnings."
            }
            Write-Host ""
            Write-Host "--- Pass 2: Vineflower ---"
            $ffStatus = Invoke-Vineflower -OutDir (Join-Path $OutDir 'vineflower') -FileAbs $FileAbs -FileExt $fileExt
            if ($ffStatus -eq 1) { return $false }
            if ($ffStatus -eq 2) {
                Write-Host "Continuing with Vineflower output because it produced usable sources despite warnings."
            }

            Show-Structure (Join-Path $OutDir 'jadx\sources') 'jadx'
            Show-Structure (Join-Path $OutDir 'vineflower\sources') 'vineflower'

            Write-Host ""
            Write-Host "=== Comparison ==="
            $jadxCount = 0; $ffCount = 0
            $jadxSources = Join-Path $OutDir 'jadx\sources'
            $ffSources   = Join-Path $OutDir 'vineflower\sources'
            if (Test-Path $jadxSources) {
                $jadxCount = (Get-ChildItem -Path $jadxSources -Recurse -Filter '*.java').Count
            }
            if (Test-Path $ffSources) {
                $ffCount = (Get-ChildItem -Path $ffSources -Recurse -Filter '*.java').Count
            }
            Write-Host "jadx:        $jadxCount Java files"
            Write-Host "Vineflower:  $ffCount Java files"

            if (Test-Path $jadxSources) {
                $jadxErrors = (Get-ChildItem -Path $jadxSources -Recurse -Filter '*.java' -File |
                    Select-String -Pattern 'JADX WARNING|JADX WARN|JADX ERROR|Code decompiled incorrectly' -SimpleMatch -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Path -Unique).Count
                Write-Host "jadx files with warnings/errors: $jadxErrors"
            }
            Write-Host ""
            Write-Host "Tip: compare specific classes between jadx/ and vineflower/ to pick the better output."
        }
    }

    return $engineOk
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
$decompileOk = Invoke-DecompileSingle -FileAbs $inputFileAbs -OutDir $Output -Label ''
if (-not $decompileOk) {
    exit 1
}

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
        $baseOk = Invoke-DecompileSingle -FileAbs $baseApk.FullName -OutDir $baseOutput -Label 'base.apk'
        if (-not $baseOk) {
            exit 1
        }

        # Decompile any split APKs that aren't just config splits
        $splitApks = $innerApks | Where-Object { $_.Name -ne 'base.apk' -and $_.Name -notmatch 'split_config\.' }
        foreach ($split in $splitApks) {
            $splitName = [IO.Path]::GetFileNameWithoutExtension($split.Name)
            Write-Host ""
            Write-Host "Decompiling $($split.Name)..."
            $splitOk = Invoke-DecompileSingle -FileAbs $split.FullName -OutDir (Join-Path $Output $splitName) -Label $split.Name
            if (-not $splitOk) {
                exit 1
            }
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
