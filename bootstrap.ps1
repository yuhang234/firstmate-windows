#Requires -Version 5.1
<#
.SYNOPSIS
  Install firstmate's Windows dependencies into Git Bash.
.DESCRIPTION
  Locates Git Bash, runs bin/fm-windows-bootstrap.sh through it (the pinned
  jq.exe, the flock shim, and the herdr pane-shell configuration), and
  persists the dependency directory on the user's PATH so future Git Bash
  and PowerShell sessions resolve jq. Idempotent; safe to re-run.
.EXAMPLE
  .\bootstrap.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$DepDir = Join-Path $env:LOCALAPPDATA 'firstmate\bin'

function Find-GitBash {
    $candidates = @()
    if ($env:GIT_INSTALL_ROOT) {
        $candidates += (Join-Path $env:GIT_INSTALL_ROOT 'bin\bash.exe')
    }
    $candidates += @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    throw 'Git Bash was not found. Install Git for Windows (https://git-scm.com/download/win) and retry.'
}

$Bash = Find-GitBash
Write-Host "Using Git Bash: $Bash"

# Run the bash bootstrap through Git Bash with the repository as cwd. The
# script is invoked as `bash <relative path>`: a Windows path handed to bash
# as a command loses its backslashes, and this form does not depend on the
# file's exec bit surviving the clone.
Push-Location $RepoRoot
try {
    & $Bash -lc "bash bin/fm-windows-bootstrap.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "fm-windows-bootstrap.sh exited with code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# Persist the dependency directory on the user PATH (idempotent) so future
# sessions - including herdr panes, which inherit the server environment -
# resolve jq without hand-editing PATH.
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $userPath) { $userPath = '' }
$entries = $userPath -split ';' | Where-Object { $_ -ne '' }
if ($entries -notcontains $DepDir) {
    $newUserPath = (@($entries) + $DepDir) -join ';'
    [Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
    Write-Host "Persisted $DepDir on the user PATH."
}
else {
    Write-Host "$DepDir is already on the user PATH."
}
$env:PATH = "$DepDir;$env:PATH"
Write-Host 'bootstrap.ps1: done. Restart any running herdr server for panes to inherit the updated PATH.'
