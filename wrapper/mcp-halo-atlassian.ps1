# Wrapper launched by Copilot CLI to start halo-mcp-atlassian.
# Phase 5+: GHCR-pinned image with health gate + automatic fallback to a known-good
# previous digest if the new image fails its self-check.
#
# Image source-of-truth: this file. Update via PR + wrapper redeploy.
# Override at runtime with $env:HALO_MCP_IMAGE (e.g. for canary testing).
# Skip pull with $env:HALO_MCP_NO_PULL=1 (offline mode; uses cached image).

$ErrorActionPreference = 'Stop'

# ---- Image pinning ----------------------------------------------------------
# Replace digests below at promotion time. Both must be valid, pulled images.
# A bad CURRENT image causes wrapper to silently fall back to PREVIOUS.
$DefaultImage  = 'ghcr.io/v-nguyenmich/halo-mcp-atlassian@sha256:82c1f51bb4de0c91440bf213663fab7657d90ae05132a54437b7625e801ebbd3'  # canary 2bc6ca7 (compact AQL + ungated list_object_type_attributes)
$CurrentImage  = $env:HALO_MCP_IMAGE        ; if (-not $CurrentImage)  { $CurrentImage  = $DefaultImage }
$PreviousImage = $env:HALO_MCP_PREV_IMAGE   ; if (-not $PreviousImage) { $PreviousImage = 'ghcr.io/v-nguyenmich/halo-mcp-atlassian@sha256:61d8452cb0bfeda8c768a4095b7014bb85ff1a44d172e4188170ebcfdf7f22ca' }  # prior canary 0e2ae95

# ---- Token from CopilotVault ------------------------------------------------
try {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    $token = Get-Secret -Name AtlassianApiToken -Vault CopilotVault -AsPlainText
}
catch {
    [Console]::Error.WriteLine("mcp-halo-atlassian wrapper: failed to read AtlassianApiToken from CopilotVault: $_")
    exit 1
}

$env:ATLASSIAN_JIRA_URL       = 'https://343industries.atlassian.net'
$env:ATLASSIAN_CONFLUENCE_URL = 'https://343industries.atlassian.net/wiki'
$env:ATLASSIAN_EMAIL          = 'v-nguyenmich@halostudios.com'
$env:ATLASSIAN_API_TOKEN      = $token

# Assets write surface: opt-in. Set both env vars in your shell/profile to
# enable create/update/delete tools. Default OFF; only AQL/get/list register.
#   $env:HALO_MCP_ASSETS_WRITE='1'
#   $env:HALO_MCP_ASSETS_WRITE_OBJECT_TYPES='123,456'   # numeric objectType ids
# Discover ids via assets_list_object_types(schema_id).

$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
if (-not (Test-Path $docker)) { $docker = (Get-Command docker).Source }

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
    '-v','D:\CopilotScripts\halo-mcp-atlassian\uploads:/uploads:ro'
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
