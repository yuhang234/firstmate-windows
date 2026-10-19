#Requires -Version 5.1
<#
.SYNOPSIS
  Start firstmate on Windows from PowerShell.
.DESCRIPTION
  Locates Git Bash, puts firstmate's Windows dependency directory (installed
  by bootstrap.ps1) on PATH, sets the environment firstmate needs, and
  launches the selected coding-agent harness inside Git Bash with this
  repository as the working directory. AGENTS.md takes over from there,
  exactly as on POSIX: the harness session IS firstmate, and the crewmates it
  spawns appear as new panes in the Herdr terminal.
.PARAMETER Agent
  The harness to launch. Defaults to claude; codebuddy, agy, opencode, and
  codex are equally valid. Whatever the agent's own CLI name is.
.PARAMETER Backend
  Optional runtime backend for spawned workers (herdr, tmux, zellij, ...).
  Forwarded as FM_BACKEND. Omit for firstmate's normal auto-detection, which
  picks herdr automatically when this session already runs inside a Herdr
  pane (HERDR_SESSION is injected there).
.PARAMETER Session
  Optional Herdr session name for spawned workers. Forwarded as HERDR_SESSION.
.PARAMETER Bootstrap
  Run bootstrap.ps1 first (installs jq and the flock shim).
.PARAMETER Args
  Remaining arguments are forwarded verbatim to the harness.
.EXAMPLE
  .\firstmate.ps1
.EXAMPLE
  .\firstmate.ps1 -Agent codebuddy
.EXAMPLE
  .\firstmate.ps1 -Bootstrap -Agent agy
#>
[CmdletBinding()]
param(
    [string]$Agent = 'claude',
    [string]$Backend = '',
    [string]$Session = '',
    [switch]$Bootstrap,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)

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

if ($Bootstrap) {
    & (Join-Path $RepoRoot 'bootstrap.ps1')
}

$Bash = Find-GitBash

# The dependency directory bootstrap.ps1 installed: jq and the flock shim.
if (Test-Path -LiteralPath $DepDir) {
    if ($env:PATH -notlike "*$DepDir*") {
        $env:PATH = "$DepDir;$env:PATH"
    }
}
elseif ($Bootstrap) {
    throw "bootstrap reported success but $DepDir does not exist"
}
else {
    Write-Warning "$DepDir is missing; run .\bootstrap.ps1 once (or pass -Bootstrap) so jq is available."
}

# Environment firstmate needs on Windows. FM_HOME pins this checkout as the
# firstmate home (the same default the bash entry points derive); the backend
# and session selectors are passed through only when the caller set them.
$env:FM_HOME = $RepoRoot
if ($Backend)  { $env:FM_BACKEND = $Backend }
if ($Session)  { $env:HERDR_SESSION = $Session }

# Quote each forwarded argument as one bash single-quoted word. A single
# quote inside the text becomes the bash escape sequence quote-backslash-
# quote-quote, built from char codes so this file needs no tricky escaping.
function ConvertTo-BashSingleQuoted {
    param([string]$Text)
    $q = [string][char]39
    $escaped = $Text -replace $q, ($q + [string][char]92 + $q + $q)
    return $q + $escaped + $q
}

$agentArg = ConvertTo-BashSingleQuoted $Agent
$extraArgs = ''
foreach ($a in $Args) {
    if ($null -ne $a) { $extraArgs = $extraArgs + ' ' + (ConvertTo-BashSingleQuoted $a) }
}

# Run the harness from the repository root. Push/Pop-Location keeps the
# caller's PowerShell location unchanged. The shell is NOT a login shell:
# a Git Bash login shell rebuilds PATH from the registry, which would drop
# the dependency directory this script just put on PATH. The bash.exe stub
# still establishes the MSYS environment (MSYSTEM=MINGW64, HOME), verified
# on the Windows host.
Push-Location $RepoRoot
try {
    & $Bash -c "exec $agentArg$extraArgs"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
