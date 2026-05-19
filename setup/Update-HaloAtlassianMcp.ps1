#requires -Version 7.0
<#
.SYNOPSIS
  Pulls the latest halo-mcp-atlassian wrapper and container image.

.DESCRIPTION
  Designed to run unattended on a weekly schedule (registered by
  Install-HaloAtlassianMcp.ps1 -RegisterAutoUpdate). Steps:
    1. git pull --ff-only on the repo
    2. Parse the new $DefaultImage digest from the freshly pulled wrapper
    3. docker pull that digest
    4. Copy wrapper + CredentialStore.ps1 to the deploy directory
  No credential prompts, no config merges. Logs to a rolling file.

.PARAMETER RepoRoot
  Path to the cloned halo-atlassian-mcp repo. Defaults to the parent of this
  script.

.PARAMETER DeployRoot
  Where to copy the wrapper scripts. Defaults to
  %LOCALAPPDATA%\Programs\halo-mcp-atlassian.

.PARAMETER LogPath
  Where to write the rolling log. Defaults to
  $env:LOCALAPPDATA\HaloMcp\update.log.

.EXAMPLE
  pwsh -NoProfile -File Update-HaloAtlassianMcp.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$DeployRoot = (Join-Path $env:LOCALAPPDATA 'Programs\halo-mcp-atlassian'),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'HaloMcp\update.log')
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Level, $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

try {
    Write-Log "update start: repo=$RepoRoot deploy=$DeployRoot"

    if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
        throw "Not a git repo: $RepoRoot"
    }

    Push-Location $RepoRoot
    try {
        $before = (& git rev-parse HEAD).Trim()
        & git fetch --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
        & git pull --ff-only --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed (non-fast-forward?)" }
        $after = (& git rev-parse HEAD).Trim()
        Write-Log "git: $before -> $after"
    } finally {
        Pop-Location
    }

    $wrapperSrc = Join-Path $RepoRoot 'wrapper\mcp-halo-atlassian.ps1'
    $helperSrc  = Join-Path $RepoRoot 'wrapper\CredentialStore.ps1'
    foreach ($p in @($wrapperSrc, $helperSrc)) {
        if (-not (Test-Path $p)) { throw "Missing source file: $p" }
    }

    $match = Select-String -Path $wrapperSrc -Pattern '\$DefaultImage\s*=\s*''([^'']+)''' |
             Select-Object -First 1
    if (-not $match) { throw "Could not parse `\$DefaultImage` from $wrapperSrc" }
    $image = $match.Matches[0].Groups[1].Value
    Write-Log "pinned image: $image"

    & docker pull $image
    if ($LASTEXITCODE -ne 0) { throw "docker pull failed for $image" }

    New-Item -ItemType Directory -Force -Path $DeployRoot | Out-Null
    Copy-Item -Force $wrapperSrc (Join-Path $DeployRoot 'mcp-halo-atlassian.ps1')
    Copy-Item -Force $helperSrc  (Join-Path $DeployRoot 'CredentialStore.ps1')
    Write-Log "deployed wrapper to $DeployRoot"

    Write-Log "update OK"
    exit 0
}
catch {
    Write-Log "update FAILED: $($_.Exception.Message)" 'ERROR'
    exit 1
}
