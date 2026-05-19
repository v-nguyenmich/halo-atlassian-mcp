# Smoke-test for a deployed halo-mcp-atlassian install.
#
# Verifies (in order):
#   1. Windows Credential Manager entry 'halo-atlassian:api-token' exists.
#   2. Wrapper deployed at <DeployRoot>\mcp-halo-atlassian.ps1.
#   3. CredentialStore helper deployed at <DeployRoot>\CredentialStore.ps1.
#   4. ~/.copilot/mcp-config.json has a 'halo-atlassian' entry pointing at
#      the deployed wrapper.
#   5. Tenant config file readable and has https://*.atlassian.net URLs.
#   6. docker.exe reachable; Docker engine responsive.
#   7. Pinned image cached locally (skip with -SkipImageCheck).
#   8. Container --check passes (skip with -SkipContainerCheck).
#
# Exit codes:
#   0 = healthy
#   1+ = number of failures
#
# Usage:
#   .\setup\Test-Installation.ps1
#   .\setup\Test-Installation.ps1 -SkipContainerCheck

[CmdletBinding()]
param(
    [string]$DeployRoot       = (Join-Path $env:LOCALAPPDATA 'Programs\halo-mcp-atlassian'),
    [string]$TenantConfigPath = (Join-Path $env:USERPROFILE '.halo-atlassian.json'),
    [string]$McpConfigPath    = (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
    [string]$SkillPath        = (Join-Path $env:USERPROFILE '.copilot\skills\halo-atlassian'),
    [string]$CredentialTarget = 'halo-atlassian:api-token',
    [switch]$SkipImageCheck,
    [switch]$SkipContainerCheck,
    [switch]$SkipSkillCheck
)

$ErrorActionPreference = 'Continue'

$fails = 0
function Check([string]$Name, [scriptblock]$Test, [string]$FixHint) {
    Write-Host -NoNewline ("  [..] {0,-50} " -f $Name)
    try {
        $r = & $Test
        if ($r) {
            Write-Host "OK" -ForegroundColor Green
        } else {
            Write-Host "FAIL" -ForegroundColor Red
            if ($FixHint) { Write-Host ("       fix: {0}" -f $FixHint) -ForegroundColor DarkYellow }
            $script:fails++
        }
    } catch {
        Write-Host "ERROR" -ForegroundColor Red
        Write-Host ("       {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        if ($FixHint) { Write-Host ("       fix: {0}" -f $FixHint) -ForegroundColor DarkYellow }
        $script:fails++
    }
}

Write-Host ''
Write-Host '=== halo-mcp-atlassian install health check ===' -ForegroundColor Cyan

# 1. Credential
$WrapperDst = Join-Path $DeployRoot 'mcp-halo-atlassian.ps1'
$HelperDst  = Join-Path $DeployRoot 'CredentialStore.ps1'

Check "credential '$CredentialTarget' present" {
    $o = & cmdkey "/list:$CredentialTarget" 2>&1 | Out-String
    $o -match 'halo-atlassian:api-token'
} "re-run setup\Install-HaloAtlassianMcp.ps1 to write the credential"

Check "wrapper deployed at $WrapperDst" {
    Test-Path $WrapperDst
} "re-run installer (-DeployRoot if you used a custom path)"

Check "helper deployed at $HelperDst" {
    Test-Path $HelperDst
} "re-run installer (helper missing or wrong path)"

# 2. mcp-config entry
Check "~/.copilot/mcp-config.json has 'halo-atlassian'" {
    if (-not (Test-Path $McpConfigPath)) { return $false }
    $cfg = Get-Content $McpConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $cfg.mcpServers -and $cfg.mcpServers.Contains('halo-atlassian')
} "re-run installer; or check `$McpConfigPath` exists"

Check "mcp-config 'halo-atlassian' points at deployed wrapper" {
    if (-not (Test-Path $McpConfigPath)) { return $false }
    $cfg = Get-Content $McpConfigPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not ($cfg.mcpServers -and $cfg.mcpServers.Contains('halo-atlassian'))) { return $false }
    $args = $cfg.mcpServers['halo-atlassian'].args
    $args -contains $WrapperDst
} "re-run installer; deploy root and mcp-config disagree"

# 3. Tenant config
Check "tenant config $TenantConfigPath valid" {
    if (-not (Test-Path $TenantConfigPath)) { return $false }
    $t = Get-Content $TenantConfigPath -Raw | ConvertFrom-Json
    $t.jira_url -match '^https://[^/]+\.atlassian\.net' -and
        $t.confluence_url -match '^https://[^/]+\.atlassian\.net'
} "re-run installer with -JiraUrl/-ConfluenceUrl"

# 4. Docker
$dockerExe = $null
Check "docker.exe on PATH or default install" {
    $cmd = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:dockerExe = $cmd.Source; return $true }
    $def = "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $def) { $script:dockerExe = $def; return $true }
    return $false
} "install Docker Desktop"

Check "docker engine responsive (docker info)" {
    if (-not $dockerExe) { return $false }
    & $dockerExe info --format '{{.ServerVersion}}' 2>$null | Out-Null
    $LASTEXITCODE -eq 0
} "start Docker Desktop"

# 5. Image cached
if (-not $SkipImageCheck) {
    Check "pinned image cached locally" {
        if (-not (Test-Path $WrapperDst)) { return $false }
        $src = Get-Content $WrapperDst -Raw
        if ($src -notmatch '\$DefaultImage\s*=\s*[''"]([^''"]+)[''"]') { return $false }
        $img = $matches[1]
        & $dockerExe image inspect $img 2>$null | Out-Null
        $LASTEXITCODE -eq 0
    } "docker pull <DefaultImage>  (the wrapper does this on first run)"
}

# 6. Container --check
if (-not $SkipContainerCheck) {
    Check "container --check passes" {
        $env:HALO_MCP_NO_PULL = '1'
        try {
            & pwsh -NoProfile -File $WrapperDst -DryRun 2>&1 | Out-Null
            return $true
        } finally {
            Remove-Item Env:\HALO_MCP_NO_PULL -ErrorAction SilentlyContinue
        }
    } "run setup\Install-HaloAtlassianMcp.ps1 — token may be expired"
}

# 7. Skill deployed
if (-not $SkipSkillCheck) {
    Check "Copilot CLI skill deployed at $SkillPath" {
        Test-Path (Join-Path $SkillPath 'SKILL.md')
    } "re-run installer or copy skills\halo-atlassian to $SkillPath"
}

Write-Host ''
if ($fails -eq 0) {
    Write-Host 'Install is healthy.' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("{0} check(s) failed." -f $fails) -ForegroundColor Red
    exit $fails
}
