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

.PARAMETER LogMaxBytes
  Rotate the log file when it exceeds this size (default 1 MB). The previous
  log is moved to <LogPath>.1; older files shift to .2, .3, ... up to
  LogMaxFiles before being discarded.

.PARAMETER LogMaxFiles
  Maximum number of rotated log files to retain (default 5).

.EXAMPLE
  pwsh -NoProfile -File Update-HaloAtlassianMcp.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$DeployRoot = (Join-Path $env:LOCALAPPDATA 'Programs\halo-mcp-atlassian'),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'HaloMcp\update.log'),
    [int]$LogMaxBytes = 1MB,
    [int]$LogMaxFiles = 5
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null

# Rotate the log file before any writes. Avoids the weekly task accumulating
# unbounded log growth on a long-running install.
function Invoke-LogRotate {
    param([string]$Path, [int]$MaxBytes, [int]$MaxFiles)
    if (-not (Test-Path $Path)) { return }
    $size = (Get-Item $Path).Length
    if ($size -lt $MaxBytes) { return }
    # Drop everything at or beyond MaxFiles (handles MaxFiles decreases).
    $leaf = Split-Path $Path -Leaf
    Get-ChildItem -Path (Split-Path $Path -Parent) -Filter ($leaf + '.*') -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name.Length -le $leaf.Length + 1) { return $false }
            $suffix = $_.Name.Substring($leaf.Length + 1)
            $n = 0
            [int]::TryParse($suffix, [ref]$n) -and $n -ge $MaxFiles
        } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Shift the rest up by one and move current to .1.
    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
        $src = "$Path.$i"
        $dst = "$Path.$($i + 1)"
        if (Test-Path $src) { Move-Item $src $dst -Force -ErrorAction SilentlyContinue }
    }
    Move-Item $Path "$Path.1" -Force -ErrorAction SilentlyContinue
}
Invoke-LogRotate -Path $LogPath -MaxBytes $LogMaxBytes -MaxFiles $LogMaxFiles

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Level, $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

# Network preflight. The weekly task runs unattended on laptops that may be
# closed / on VPN / on captive WiFi. Fail fast (< 5s) instead of hanging the
# 15-minute task budget on git fetch or docker pull timeouts.
function Test-NetworkReachable {
    param([string[]]$Hosts = @('github.com', 'ghcr.io'), [int]$TimeoutMs = 3000)
    foreach ($h in $Hosts) {
        try {
            $req = [System.Net.WebRequest]::Create("https://$h")
            $req.Method = 'HEAD'
            $req.Timeout = $TimeoutMs
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        } catch {
            # Try the next host before declaring offline.
            continue
        }
    }
    return $false
}

try {
    Write-Log "update start: repo=$RepoRoot deploy=$DeployRoot"

    if (-not (Test-NetworkReachable)) {
        Write-Log 'network preflight failed: github.com and ghcr.io both unreachable; skipping this run' 'WARN'
        exit 0
    }
    Write-Log 'network preflight OK'

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

