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
    param([Parameter(Mandatory = $true)][string]$Value)
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
            if ($cmd -and $cmd.Source) {
                return [pscustomobject]@{ Kind = $kind; Path = $cmd.Source }
            }
        }
    }

    $candidates = Get-ToolField -Id $Id -Column 'candidates'
    if ($null -eq $candidates) { return $null }
    if ($candidates -cne '-') {
        foreach ($c in ($candidates -split ';')) {
            $expanded = Expand-ToolPlaceholders -Value $c
            if (Test-Path -LiteralPath $expanded -PathType Leaf) {
                return [pscustomobject]@{ Kind = $kind; Path = $expanded }
            }
        }
    }

    return $null
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
