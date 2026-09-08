#Requires -Version 5.1
# Tools.ps1 - the single source of truth for locating the plugin's tools.
#
# Dot-sourced by check-deps.ps1, decompile.ps1 and install-dep.ps1. Mirrors
# tools.sh exactly: same resolution order (env override -> PATH probe ->
# candidate paths), same PSV, same placeholder rules. The two readers must
# agree exactly - a divergence here recreates the bug this file exists to
# eliminate.
#
# Deliberately does not use Import-Csv: it follows RFC4180 quoting rules,
# which bash's `read` does not. Splitting the lines by hand here guarantees
# both readers apply identical rules to the same input.
#
# PowerShell 5.1 compatible: no ??, no ?., no &&, no -Parallel.

function Get-ToolsPsvPath {
    if ($env:CLAUDE_PLUGIN_ROOT) {
        $candidate = Join-Path $env:CLAUDE_PLUGIN_ROOT 'skills/android-reverse-engineering/scripts/lib/tools.psv'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    # Fallback: alongside this file. Breaks under a symlinked invocation,
    # which is why CLAUDE_PLUGIN_ROOT is preferred.
    return (Join-Path $PSScriptRoot 'tools.psv')
}

function Get-ToolsLines {
    $psv = Get-ToolsPsvPath
    if (-not (Test-Path -LiteralPath $psv -PathType Leaf)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $psv -Raw -Encoding UTF8
    $lines = [regex]::Split($raw, "\r\n|\n")
    # A trailing newline in the file produces one trailing empty element
    # after the split; drop it so it isn't mistaken for a blank PSV line.
    if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -ceq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }
    return $lines
}

function Expand-ToolPlaceholders {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    # Expands {HOME} and {LOCALAPPDATA} in a candidate path.
    #
    # {LOCALAPPDATA} exists so a single candidates list can carry
    # Windows-only locations (spelled with the .bat extension Windows
    # actually needs, resolved against $env:LOCALAPPDATA) alongside Unix
    # locations in the same tools.psv row: both readers only test file
    # existence, so a Windows-only candidate simply never matches on Unix
    # and vice versa - no platform-column branching required (fix round 1,
    # Finding 1). $env:LOCALAPPDATA is expected to be set on every real
    # Windows session; if it's ever empty, this expands the placeholder to
    # the empty string and the resulting candidate simply fails the
    # existence test below, exactly like any other non-existent candidate.
    #
    # NOT cross-reader tested as a raw string: $env:USERPROFILE/
    # $env:LOCALAPPDATA and bash's $HOME/$LOCALAPPDATA are different
    # literal strings even on the same Git-Bash-on-Windows machine (e.g.
    # C:\Users\foo vs /c/Users/foo), so a verbatim string comparison of the
    # *expanded literal* between tools.sh's _tools_expand and this function
    # is structurally meaningless - it would always "diverge" even when
    # both are correct. What tests/test-tools-psv.sh checks instead
    # (same-platform) is that both readers expand a placeholder to a path
    # that resolves to the SAME file on disk, which is the actual property
    # that matters.
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { $homeDir = $HOME }
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = '' }
    return $Value.Replace('{HOME}', $homeDir).Replace('{LOCALAPPDATA}', $localAppData)
}

# Split-PsvRow -Line <line>
# Splits one '|'-delimited PSV line into fields. Deliberately NOT just
# `$line -split '\|'`: plain -split keeps a trailing empty element when
# the line ends with the delimiter (e.g. 'a|b|' -> @('a','b','')), while
# bash's `for f in $line` with IFS='|' drops exactly that one trailing
# empty field (verified: 'a|b|' -> 2 fields, 'a|||' -> 3 fields - always
# exactly one fewer than a naive split when the line ends with the
# delimiter). Without this, a row whose last column is empty is read as
# present-and-empty here but absent in tools.sh - the two readers would
# disagree about whether the column exists at all.
function Split-PsvRow {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    $fields = $Line -split '\|'
    if ($fields.Length -eq 1 -and $fields[0] -ceq '') {
        return , @()
    }
    if ($fields.Length -gt 0 -and $fields[$fields.Length - 1] -ceq '') {
        $fields = $fields[0..($fields.Length - 2)]
    }
    return , $fields
}

# Get-ToolField -Id <id> -Column <column-name>
# Prints the raw field, or returns $null if the id or column is unknown.
function Get-ToolField {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Column
    )
    $lines = Get-ToolsLines
    if (-not $lines -or $lines.Count -eq 0) { return $null }

    $header = Split-PsvRow -Line $lines[0]
    $foundIndex = -1
    for ($i = 0; $i -lt $header.Length; $i++) {
        # -ceq: case-sensitive, matching bash's byte-exact `[ "$col" =
        # "$want_col" ]`. Plain -eq on strings is culture-aware and
        # case-INsensitive in PowerShell ('JAR' -eq 'jar' is $true),
        # which would silently accept a typo'd or wrongly-cased column
        # name here that tools.sh would correctly reject.
        if ($header[$i] -ceq $Column) { $foundIndex = $i; break }
    }
    if ($foundIndex -lt 0) { return $null }

    $prefix = "$Id|"
    foreach ($line in $lines) {
        if (-not $line.StartsWith($prefix)) { continue }
        $fields = Split-PsvRow -Line $line
        if ($foundIndex -lt $fields.Length) {
            return $fields[$foundIndex]
        }
    }
    return $null
}

# Resolve-Tool -Id <id>
# Returns [pscustomobject]@{ Kind = 'cli'|'jar'; Path = <string> } for the
# resolved artifact (an executable or a .jar), or $null if it cannot be
# found. Resolution order: env override -> PATH probe -> candidate paths.
# Test-ToolPython3 <path>
# True only when <path> is a working Python 3.
#
# Presence is not evidence on Windows. The Microsoft Store installs an
# app-execution alias named python3 into %LOCALAPPDATA%\Microsoft\
# WindowsApps: a real file that Get-Command finds and that exits 49 with
# no output, opening the Store when run from a prompt. python.org's
# Windows installer, meanwhile, creates python.exe and pythonw.exe but
# never a python3.exe - only a python3.dll - so the NAME python3 can
# resolve to the stub and to nothing else, however many real
# interpreters are installed. Mirrors _tools_verify_python3 in tools.sh.
function Test-ToolPython3 {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $out = & $Path -c 'import sys; print(sys.version_info[0])' 2>$null
    } catch {
        return $false
    }
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($out | Select-Object -First 1) -ceq '3')
}

# Test-ToolAcceptable <id> <path>
# True when <path> is not merely present but usable as <id>.
#
# Only consulted for probe hits and candidate paths - the guesses. An
# explicit env override is a statement of intent and is honoured as
# given. Mirrors _tools_accept in tools.sh.
function Test-ToolAcceptable {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $verify = Get-ToolField -Id $Id -Column 'verify'
    if ($null -eq $verify -or $verify -ceq '-' -or $verify -ceq '') { return $true }
    switch -CaseSensitive ($verify) {
        'python3' { return (Test-ToolPython3 -Path $Path) }
        default {
            # An unrecognised verifier name is a manifest error.
            # Accepting anyway would silently downgrade to no
            # verification, which is what this column exists to prevent.
            Write-Error "Tools.ps1: tools.psv names an unknown verify '$verify' for tool '$Id'"
            return $false
        }
    }
}

function Resolve-Tool {
    param([Parameter(Mandatory = $true)][string]$Id)

    $psvKind = Get-ToolField -Id $Id -Column 'kind'
    if ($null -eq $psvKind) { return $null }
    $kind = 'cli'
    if ($psvKind -ceq 'jar') { $kind = 'jar' }

    $envName = Get-ToolField -Id $Id -Column 'env_override'
    if ($null -eq $envName) { return $null }
    if ($envName -cne '-') {
        $envVal = [Environment]::GetEnvironmentVariable($envName)
        if ($envVal -and (Test-Path -LiteralPath $envVal -PathType Leaf)) {
            return [pscustomobject]@{ Kind = $kind; Path = $envVal }
        }
    }

    $probe = Get-ToolField -Id $Id -Column 'probe'
    if ($null -eq $probe) { return $null }
    if ($probe -cne '-') {
        foreach ($p in ($probe -split ',')) {
            $cmd = Get-Command $p -CommandType Application -ErrorAction SilentlyContinue
            # Keep going past a name that exists but does not work: on
            # Windows the first name in python3's probe list resolves to
            # the Store stub every time, and stopping there reported
            # [MISSING] on machines with a working Python installed
            # under a different name.
            if ($cmd -and $cmd.Source -and (Test-ToolAcceptable -Id $Id -Path $cmd.Source)) {
                # A jar-kind tool (per tools.psv) can still be found on PATH
                # as a real CLI launcher (e.g. a package manager's
                # `vineflower` script) rather than the raw .jar this
                # project's own installer places at the candidate paths.
                # A probe match is always something directly executable,
                # regardless of what tools.psv says the installed artifact
                # normally is - report it as 'cli' so a caller invokes it
                # directly instead of wrapping it in `java -jar`, which
                # would fail immediately. Mirrors the equivalent fix in
                # tools.sh's tool_argv.
                return [pscustomobject]@{ Kind = 'cli'; Path = $cmd.Source }
            }
        }
    }

    $candidates = Get-ToolField -Id $Id -Column 'candidates'
    if ($null -eq $candidates) { return $null }
    if ($candidates -cne '-') {
        foreach ($c in ($candidates -split ';')) {
            # An empty element (e.g. a stray ";;" in the candidates list)
            # must be skipped, not fed onward: bash's equivalent loop in
            # tools.sh's tool_resolve harmlessly no-ops on an empty
            # candidate (`[ -f "" ]` is simply false), but here
            # Test-Path -LiteralPath '' throws under this project's
            # $ErrorActionPreference = 'Stop', aborting the whole calling
            # script before it can reach a later candidate bash would still
            # find. Skipping explicitly keeps both readers' behavior
            # identical instead of relying on Test-Path to fail the same
            # way bash's `[ -f ]` does.
            if (-not $c) { continue }
            $expanded = Expand-ToolPlaceholders -Value $c
            if ((Test-Path -LiteralPath $expanded -PathType Leaf) -and
                (Test-ToolAcceptable -Id $Id -Path $expanded)) {
                return [pscustomobject]@{ Kind = $kind; Path = $expanded }
            }
        }
    }

    return $null
}

# Get-ToolArgv -Id <id>
# Mirrors tools.sh's tool_argv: returns the full argv (a string array) needed
# to run the tool named by <id>, or $null if it cannot be resolved. For
# kind=path (per Resolve-Tool's disambiguated Kind, not the static tools.psv
# column - a probe match on a jar-kind id is reported as Kind='cli' by
# Resolve-Tool itself) this is a single-element array holding the resolved
# executable. For kind=jar it is a three-element array (java, '-jar', <jar
# path>), with java resolved through Resolve-Tool -Id 'java' rather than a
# hard-coded 'java' literal - this is the C1 fix: before this function
# existed, decompile.ps1 had nowhere to get a resolved java from and called
# the bare 'java' command directly, which ignores JAVA_BIN and every
# tools.psv candidate entirely.
function Get-ToolArgv {
    param([Parameter(Mandatory = $true)][string]$Id)

    $resolved = Resolve-Tool -Id $Id
    if (-not $resolved) { return $null }

    if ($resolved.Kind -eq 'jar') {
        $java = Resolve-Tool -Id 'java'
        if (-not $java) { return $null }
        return @($java.Path, '-jar', $resolved.Path)
    }

    # The unary comma forces this single-element array onto the pipeline
    # as one array object rather than unrolled as a bare string: `return
    # @($x)` on its own, with exactly one element, gets collapsed by
    # PowerShell's pipeline output handling into the scalar $x itself, so
    # a caller's `$argv[0]` would silently index into the STRING (its
    # first character) instead of the array. Same reasoning as
    # Split-PsvRow's `return , @()` above.
    return , @($resolved.Path)
}

# Get-ToolList [-Want required|optional]
function Get-ToolList {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('required', 'optional')]
        [string]$Want
    )
    $lines = Get-ToolsLines
    if (-not $lines) { return @() }

    $result = @()
    $first = $true
    foreach ($line in $lines) {
        if ($first) { $first = $false; continue }
        if ($line -ceq '' -or $line.StartsWith('#')) { continue }
        $id = $line.Split('|')[0]
        if ($id.StartsWith('#')) { continue }
        if ($Want) {
            $req = Get-ToolField -Id $id -Column 'required'
            # -cne: case-sensitive. -ValidateSet on $Want accepts its
            # values case-insensitively, so a plain -ne here would let a
            # differently-cased $Want silently match a $req that
            # tools.sh's byte-exact `[ "$req" = "$want" ]` would reject.
            if ($req -cne $Want) { continue }
        }
        $result += $id
    }
    return $result
}
