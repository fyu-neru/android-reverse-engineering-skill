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
    if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }
    return $lines
}

function Expand-ToolHome {
    param([Parameter(Mandatory = $true)][string]$Value)
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { $homeDir = $HOME }
    return $Value.Replace('{HOME}', $homeDir)
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

    $header = $lines[0] -split '\|'
    $foundIndex = -1
    for ($i = 0; $i -lt $header.Length; $i++) {
        if ($header[$i] -eq $Column) { $foundIndex = $i; break }
    }
    if ($foundIndex -lt 0) { return $null }

    $prefix = "$Id|"
    foreach ($line in $lines) {
        if (-not $line.StartsWith($prefix)) { continue }
        $fields = $line -split '\|'
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
    if ($psvKind -eq 'jar') { $kind = 'jar' }

    $envName = Get-ToolField -Id $Id -Column 'env_override'
    if ($null -eq $envName) { return $null }
    if ($envName -ne '-') {
        $envVal = [Environment]::GetEnvironmentVariable($envName)
        if ($envVal -and (Test-Path -LiteralPath $envVal -PathType Leaf)) {
            return [pscustomobject]@{ Kind = $kind; Path = $envVal }
        }
    }

    $probe = Get-ToolField -Id $Id -Column 'probe'
    if ($null -eq $probe) { return $null }
    if ($probe -ne '-') {
        foreach ($p in ($probe -split ',')) {
            $cmd = Get-Command $p -CommandType Application -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) {
                return [pscustomobject]@{ Kind = $kind; Path = $cmd.Source }
            }
        }
    }

    $candidates = Get-ToolField -Id $Id -Column 'candidates'
    if ($null -eq $candidates) { return $null }
    if ($candidates -ne '-') {
        foreach ($c in ($candidates -split ';')) {
            $expanded = Expand-ToolHome -Value $c
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
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $id = $line.Split('|')[0]
        if ($id.StartsWith('#')) { continue }
        if ($Want) {
            $req = Get-ToolField -Id $id -Column 'required'
            if ($req -ne $Want) { continue }
        }
        $result += $id
    }
    return $result
}
