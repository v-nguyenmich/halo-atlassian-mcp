# Wrapper launched by Copilot CLI to start halo-mcp-atlassian.
# Phase 5+: GHCR-pinned image with health gate + automatic fallback to a known-good
# previous digest if the new image fails its self-check.
#
# Credentials: Windows Credential Manager generic entry
#   target=halo-atlassian:api-token, UserName=email, Password=API token.
# Tenant URLs: tenant config file (default %USERPROFILE%\.halo-atlassian.json),
#   or env override ($env:ATLASSIAN_JIRA_URL / $env:ATLASSIAN_CONFLUENCE_URL).
# Both are provisioned by setup\Install-HaloAtlassianMcp.ps1.
#
# Image source-of-truth: this file. Update via PR + wrapper redeploy.
# Override at runtime with $env:HALO_MCP_IMAGE (e.g. for canary testing).
# Skip pull with $env:HALO_MCP_NO_PULL=1 (offline mode; uses cached image).
#
# Debugging: pass -DryRun to print the resolved docker invocation and exit
# without pulling, health-checking, or starting the MCP server.

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- Image pinning ----------------------------------------------------------
# Replace digests below at promotion time. Both must be valid, pulled images.
# A bad CURRENT image causes wrapper to silently fall back to PREVIOUS.
# These lines are auto-rewritten by ci.yml (open-wrapper-bump PR) after a green
# build promotes a new :stable digest. Keep the exact assignment shape:
#   $DefaultImage  = '<image>@sha256:<hex>'   # any trailing comment is preserved
#   $PreviousImage = $env:HALO_MCP_PREV_IMAGE ; if (-not $PreviousImage) { $PreviousImage = '<image>@sha256:<hex>' }
$DefaultImage  = 'ghcr.io/v-nguyenmich/halo-mcp-atlassian@sha256:c9781b085525b701992a945cf3c279f74b6641013e5b5738b933cdf1e683433b'  # auto-bumped from efa268ab5d4b7a010d74afac45e85a192c590e1d
$CurrentImage  = $env:HALO_MCP_IMAGE        ; if (-not $CurrentImage)  { $CurrentImage  = $DefaultImage }
$PreviousImage = $env:HALO_MCP_PREV_IMAGE   ; if (-not $PreviousImage) { $PreviousImage = 'ghcr.io/v-nguyenmich/halo-mcp-atlassian@sha256:82c1f51bb4de0c91440bf213663fab7657d90ae05132a54437b7625e801ebbd3' }  # prior canary 0e2ae95

# ---- Credentials from Windows Credential Manager ----------------------------
# Helper is shipped alongside this wrapper by the installer; running directly
# out of a clone falls back to the repo path two directories up.
$helperCandidates = @(@(
    (Join-Path $PSScriptRoot 'CredentialStore.ps1'),
    (Join-Path $PSScriptRoot '..\wrapper\CredentialStore.ps1')
) | Where-Object { Test-Path $_ })
if (-not $helperCandidates) {
    [Console]::Error.WriteLine("mcp-halo-atlassian: CredentialStore.ps1 not found; reinstall via setup\Install-HaloAtlassianMcp.ps1")
    exit 1
}
. $helperCandidates[0]

try {
    $cred = Get-HaloAtlassianCredential
}
catch {
    [Console]::Error.WriteLine("mcp-halo-atlassian: failed to read credential from Windows Credential Manager: $_")
    exit 1
}
if (-not $cred -or -not $cred.Token -or -not $cred.Email) {
    [Console]::Error.WriteLine("mcp-halo-atlassian: no credential found at target 'halo-atlassian:api-token'.")
    [Console]::Error.WriteLine("Run: pwsh -File <repo>\setup\Install-HaloAtlassianMcp.ps1")
    exit 1
}

# ---- Tenant URLs ------------------------------------------------------------
# Resolution order: env override -> tenant config file -> error.
# Config file is written by the installer; nothing tenant-specific is committed.
if (-not $env:ATLASSIAN_JIRA_URL -or -not $env:ATLASSIAN_CONFLUENCE_URL) {
    $tenantConfigPath = if ($env:HALO_MCP_TENANT_CONFIG) { $env:HALO_MCP_TENANT_CONFIG } else {
        Join-Path $env:USERPROFILE '.halo-atlassian.json'
    }
    if (Test-Path $tenantConfigPath) {
        try {
            $tc = Get-Content $tenantConfigPath -Raw | ConvertFrom-Json
            if (-not $env:ATLASSIAN_JIRA_URL       -and $tc.jira_url)       { $env:ATLASSIAN_JIRA_URL       = $tc.jira_url }
            if (-not $env:ATLASSIAN_CONFLUENCE_URL -and $tc.confluence_url) { $env:ATLASSIAN_CONFLUENCE_URL = $tc.confluence_url }
        }
        catch {
            [Console]::Error.WriteLine("mcp-halo-atlassian: failed to parse tenant config '$tenantConfigPath': $_")
            exit 1
        }
    }
}
if (-not $env:ATLASSIAN_JIRA_URL -or -not $env:ATLASSIAN_CONFLUENCE_URL) {
    $msg = @(
        "mcp-halo-atlassian: tenant URLs not configured."
        "Run: pwsh -File <repo>\setup\Install-HaloAtlassianMcp.ps1"
        "Or set `$env:ATLASSIAN_JIRA_URL and `$env:ATLASSIAN_CONFLUENCE_URL."
    )
    if ($DryRun) {
        $msg | ForEach-Object { Write-Host "DRYRUN WARNING: $_" }
    }
    else {
        $msg | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit 1
    }
}
$env:ATLASSIAN_EMAIL     = $cred.Email
$env:ATLASSIAN_API_TOKEN = $cred.Token

# Assets write surface: opt-in. Set both env vars in your shell/profile to
# enable create/update/delete tools. Default OFF; only AQL/get/list register.
#   $env:HALO_MCP_ASSETS_WRITE='1'
#   $env:HALO_MCP_ASSETS_WRITE_OBJECT_TYPES='123,456'   # numeric objectType ids
# Discover ids via assets_list_object_types(schema_id).

$docker = $null
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) { $docker = $dockerCmd.Source }
if (-not $docker) {
    $dockerDefault = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    if (Test-Path $dockerDefault) { $docker = $dockerDefault }
}
if (-not $docker) {
    [Console]::Error.WriteLine("mcp-halo-atlassian: docker.exe not found in PATH or default install location.")
    [Console]::Error.WriteLine("Install Docker Desktop: https://www.docker.com/products/docker-desktop/")
    exit 1
}

# Detect Docker engine running before we issue pulls (which would hang or error
# with a generic ECONNREFUSED). `docker info` is fast when the engine is up.
& $docker info *> $null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("mcp-halo-atlassian: Docker Desktop is not running. Start it and re-run copilot.")
    exit 1
}

# Uploads bind-mount: derived from this wrapper's location so non-D:\ installs
# work without surgery. Auto-create on first run; read-only inside the container.
$uploadsHost = Join-Path $PSScriptRoot 'uploads'
if (-not (Test-Path $uploadsHost)) {
    try { New-Item -ItemType Directory -Path $uploadsHost -Force | Out-Null } catch {
        [Console]::Error.WriteLine("mcp-halo-atlassian: failed to create uploads dir '$uploadsHost': $_")
        exit 1
    }
}

$dockerArgs = @(
    'run','--rm','-i',
    '--read-only',
    '--cap-drop=ALL',
    '--security-opt=no-new-privileges',
    '--tmpfs','/tmp:rw,noexec,nosuid,size=16m',
    '-e','ATLASSIAN_JIRA_URL',
    '-e','ATLASSIAN_CONFLUENCE_URL',
    '-e','ATLASSIAN_EMAIL',
    '-e','ATLASSIAN_API_TOKEN',
    '-e','HALO_MCP_ASSETS_WRITE',
    '-e','HALO_MCP_ASSETS_WRITE_OBJECT_TYPES',
    '-v',("{0}:/uploads:ro" -f $uploadsHost)
)

function Invoke-Pull($image) {
    if ($env:HALO_MCP_NO_PULL) { return $true }
    # Local tag with no registry prefix? Skip pull (local-only image).
    if ($image -notmatch '/') { return $true }
    & $docker pull --quiet $image *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-Health($image) {
    # --check exits 0 on success. Redirect stdin from NUL so the server
    # doesn't sit waiting for MCP traffic on a TTY.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $docker
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    foreach ($a in @('run','--rm') + $dockerArgs[2..($dockerArgs.Length - 1)] + @($image,'--check')) {
        $psi.ArgumentList.Add($a) | Out-Null
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $p.WaitForExit(20000) | Out-Null
    if (-not $p.HasExited) { $p.Kill(); return $false }
    return ($p.ExitCode -eq 0)
}

# ---- Choose image -----------------------------------------------------------
$image = $CurrentImage

if ($DryRun) {
    Write-Host "DRYRUN: docker = $docker"
    Write-Host "DRYRUN: image  = $image"
    Write-Host "DRYRUN: uploads host path = $uploadsHost"
    Write-Host "DRYRUN: full command:"
    Write-Host ("  {0} {1} {2}" -f $docker, ($dockerArgs -join ' '), $image)
    exit 0
}

[void](Invoke-Pull $image)

if (-not (Test-Health $image)) {
    [Console]::Error.WriteLine("mcp-halo-atlassian: health check FAILED for $image")
    if ($PreviousImage -and ($PreviousImage -ne $CurrentImage)) {
        [Console]::Error.WriteLine("mcp-halo-atlassian: falling back to $PreviousImage")
        [void](Invoke-Pull $PreviousImage)
        if (Test-Health $PreviousImage) {
            $image = $PreviousImage
        }
        else {
            [Console]::Error.WriteLine("mcp-halo-atlassian: fallback image also unhealthy; aborting")
            exit 1
        }
    }
    else {
        [Console]::Error.WriteLine("mcp-halo-atlassian: no fallback image set; aborting")
        exit 1
    }
}

# ---- Serve MCP --------------------------------------------------------------
& $docker @dockerArgs $image
