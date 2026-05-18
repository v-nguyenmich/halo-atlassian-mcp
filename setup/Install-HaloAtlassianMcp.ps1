# Installer for the halo-mcp-atlassian MCP server on a fresh Windows machine.
#
# What it does:
#   1. Verifies prerequisites (pwsh 7+, Docker Desktop, Node + Copilot CLI).
#   2. Prompts (or accepts via -Email / -Token) for Atlassian email + API token.
#   3. Stores them in Windows Credential Manager under target
#        'halo-atlassian:api-token'  (Generic credential).
#   4. Copies the wrapper + helper into D:\CopilotScripts\.
#   5. Merges (without overwriting other entries) a 'halo-atlassian' block
#      into %USERPROFILE%\.copilot\mcp-config.json.
#   6. docker pull's the pinned image digest.
#   7. Runs the container's --check self-test.
#   8. Prints next steps.
#
# Idempotent. Re-run to rotate the token (no other side effects).
#
# Usage:
#   .\setup\Install-HaloAtlassianMcp.ps1                       # interactive
#   .\setup\Install-HaloAtlassianMcp.ps1 -DryRun               # show actions only
#   .\setup\Install-HaloAtlassianMcp.ps1 -Email a@b -Token xx  # non-interactive
#
# Exit codes:
#   0 = success or DryRun completed
#   1 = missing prerequisite
#   2 = credential write failed
#   3 = mcp-config.json merge failed
#   4 = docker pull failed
#   5 = --check health gate failed

[CmdletBinding()]
param(
    [string]$Email,
    [string]$Token,
    [string]$DeployRoot = 'D:\CopilotScripts',
    [switch]$DryRun,
    [switch]$SkipPull,
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'

# ---- Paths ------------------------------------------------------------------
$RepoRoot       = Split-Path -Parent $PSScriptRoot
$WrapperSrc     = Join-Path $RepoRoot 'wrapper\mcp-halo-atlassian.ps1'
$HelperSrc      = Join-Path $RepoRoot 'wrapper\CredentialStore.ps1'
$WrapperDst     = Join-Path $DeployRoot 'mcp-halo-atlassian.ps1'
$HelperDst      = Join-Path $DeployRoot 'CredentialStore.ps1'
$ConfigDir      = Join-Path $env:USERPROFILE '.copilot'
$ConfigPath     = Join-Path $ConfigDir 'mcp-config.json'

if (-not (Test-Path $WrapperSrc)) { throw "wrapper source missing: $WrapperSrc" }
if (-not (Test-Path $HelperSrc))  { throw "helper source missing: $HelperSrc" }

function Write-Step  ([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok    ([string]$msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2 ([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Dry   ([string]$msg) { Write-Host "    [DRYRUN] $msg" -ForegroundColor DarkGray }

# ---- 1. Prerequisites -------------------------------------------------------
Write-Step 'Checking prerequisites'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error 'PowerShell 7+ is required. Install pwsh and re-run.'
    exit 1
}
Write-Ok ("pwsh {0}" -f $PSVersionTable.PSVersion)

$docker = $null
foreach ($p in @('C:\Program Files\Docker\Docker\resources\bin\docker.exe',
                 (Get-Command docker -ErrorAction SilentlyContinue).Source)) {
    if ($p -and (Test-Path $p)) { $docker = $p; break }
}
if (-not $docker) {
    Write-Error 'Docker Desktop not found. Install Docker Desktop and ensure it is running.'
    exit 1
}
Write-Ok "docker: $docker"

try { & $docker info *> $null } catch { }
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Docker daemon is not responding. Start Docker Desktop and re-run.'
    exit 1
}
Write-Ok 'docker daemon reachable'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warn2 'node not found - Copilot CLI install (last step) will fail until you install Node LTS.'
}

# ---- 2. Email + Token (prompt unless supplied) -----------------------------
Write-Step 'Atlassian credential'

if (-not $Email) {
    $Email = Read-Host 'Atlassian email (e.g. you@halostudios.com)'
}
if (-not $Email) { throw 'Email is required.' }

if (-not $Token) {
    $sec = Read-Host 'Atlassian API token (input hidden; create at https://id.atlassian.com/manage-profile/security/api-tokens)' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $Token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
if (-not $Token) { throw 'Token is required.' }

# ---- 3. Write to Credential Manager ----------------------------------------
Write-Step 'Writing credential to Windows Credential Manager'
. $HelperSrc

if ($DryRun) {
    Write-Dry "Set-HaloAtlassianCredential -Email '$Email' -Token <hidden>"
}
else {
    try {
        Set-HaloAtlassianCredential -Email $Email -Token $Token
        $back = Get-HaloAtlassianCredential
        if (-not $back -or $back.Token -ne $Token -or $back.Email -ne $Email) {
            throw 'round-trip read did not return expected values'
        }
        Write-Ok "credential stored: target=halo-atlassian:api-token user=$Email"
    }
    catch {
        Write-Error "Failed to write credential: $_"
        exit 2
    }
}

# ---- 4. Copy wrapper + helper to deploy root --------------------------------
Write-Step "Deploying wrapper to $DeployRoot"
if ($DryRun) {
    Write-Dry "New-Item $DeployRoot -ItemType Directory -Force"
    Write-Dry "Copy-Item $WrapperSrc -> $WrapperDst"
    Write-Dry "Copy-Item $HelperSrc  -> $HelperDst"
}
else {
    New-Item -ItemType Directory -Path $DeployRoot -Force | Out-Null
    Copy-Item $WrapperSrc $WrapperDst -Force
    Copy-Item $HelperSrc  $HelperDst  -Force
    Write-Ok "deployed: $WrapperDst"
    Write-Ok "deployed: $HelperDst"
}

# ---- 5. Merge mcp-config.json ----------------------------------------------
Write-Step "Updating $ConfigPath"
$desiredEntry = [ordered]@{
    type    = 'local'
    command = 'pwsh.exe'
    args    = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $WrapperDst
    )
    tools   = @('*')
    env     = @{}
}

if ($DryRun) {
    Write-Dry "ensure mcpServers.halo-atlassian -> $WrapperDst (preserves other servers)"
}
else {
    try {
        if (Test-Path $ConfigPath) {
            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            if (-not $cfg) { $cfg = @{} }
        }
        else {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
            $cfg = @{}
        }

        if (-not $cfg.ContainsKey('mcpServers')) { $cfg['mcpServers'] = @{} }
        $cfg['mcpServers']['halo-atlassian'] = $desiredEntry

        ($cfg | ConvertTo-Json -Depth 10) | Set-Content $ConfigPath -Encoding UTF8
        Write-Ok "mcp-config.json updated (other servers preserved)"
    }
    catch {
        Write-Error "Failed to update mcp-config.json: $_"
        exit 3
    }
}

# ---- 6. Pull pinned image ---------------------------------------------------
$pinned = (Select-String -Path $WrapperSrc -Pattern '^\$DefaultImage\s*=\s*''([^'']+)''' |
           Select-Object -First 1).Matches.Groups[1].Value
if (-not $pinned) { Write-Warn2 'Could not parse $DefaultImage from wrapper; skipping pull.' }
elseif ($SkipPull) { Write-Warn2 'SkipPull set; skipping docker pull.' }
else {
    Write-Step "Pulling $pinned"
    if ($DryRun) {
        Write-Dry "docker pull $pinned"
    }
    else {
        & $docker pull $pinned
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'docker pull failed.'
            exit 4
        }
        Write-Ok 'image pulled'
    }
}

# ---- 7. --check health gate -------------------------------------------------
if ($SkipCheck) { Write-Warn2 'SkipCheck set; skipping --check.' }
else {
    Write-Step 'Running container --check'
    if ($DryRun) {
        Write-Dry "docker run --rm -e ATLASSIAN_* $pinned --check"
    }
    elseif ($pinned) {
        $checkArgs = @(
            'run','--rm',
            '--read-only','--cap-drop=ALL','--security-opt=no-new-privileges',
            '--tmpfs','/tmp:rw,noexec,nosuid,size=16m',
            '-e',"ATLASSIAN_JIRA_URL=https://343industries.atlassian.net",
            '-e',"ATLASSIAN_CONFLUENCE_URL=https://343industries.atlassian.net/wiki",
            '-e',"ATLASSIAN_EMAIL=$Email",
            '-e',"ATLASSIAN_API_TOKEN=$Token",
            $pinned,'--check'
        )
        & $docker @checkArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error '--check failed. Token may be invalid or Atlassian unreachable.'
            exit 5
        }
        Write-Ok '--check passed'
    }
}

# ---- 8. Next steps ----------------------------------------------------------
Write-Host ''
Write-Host '==> Done.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next:'
Write-Host '  1. npm install -g @github/copilot   (if not already installed)'
Write-Host '  2. copilot'
Write-Host '  3. In session:  /tools              (should list halo-atlassian-* tools)'
Write-Host ''
Write-Host 'To rotate the token: re-run this script.'
Write-Host 'To inspect the credential: cmdkey /list:halo-atlassian:api-token'
