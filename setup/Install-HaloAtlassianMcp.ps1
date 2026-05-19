# Installer for the halo-mcp-atlassian MCP server on a fresh Windows machine.
#
# What it does:
#   1. Verifies prerequisites (pwsh 7+, Docker Desktop, Node + Copilot CLI).
#   2. Prompts (or accepts via -Email / -Token) for Atlassian email + API token.
#   3. Stores them in Windows Credential Manager under target
#        'halo-atlassian:api-token'  (Generic credential).
#   3b. Writes a tenant config (Jira/Confluence base URLs) to
#        %USERPROFILE%\.halo-atlassian.json (non-secret, per-user, not
#        committed). Pass -JiraUrl / -ConfluenceUrl for non-interactive.
#   4. Copies the wrapper + helper into the deploy root (default
#      %LOCALAPPDATA%\Programs\halo-mcp-atlassian; override with -DeployRoot).
#   5. Merges (without overwriting other entries) a 'halo-atlassian' block
#      into %USERPROFILE%\.copilot\mcp-config.json.
#   6. docker pull's the pinned image digest.
#   7. Runs the container's --check self-test.
#   8. Registers a weekly Windows Scheduled Task that runs
#      Update-HaloAtlassianMcp.ps1 (git pull + docker pull + redeploy wrapper)
#      so the user gets auto-maintenance with zero manual steps. Skip with
#      -SkipAutoUpdate.
#   9. Prints next steps.
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
    [string]$JiraUrl,
    [string]$ConfluenceUrl,
    [string]$DeployRoot = (Join-Path $env:LOCALAPPDATA 'Programs\halo-mcp-atlassian'),
    [string]$TenantConfigPath = (Join-Path $env:USERPROFILE '.halo-atlassian.json'),
    [string]$SkillRoot = (Join-Path $env:USERPROFILE '.copilot\skills'),
    [switch]$DryRun,
    [switch]$SkipPull,
    [switch]$SkipCheck,
    [switch]$SkipAutoUpdate,
    [switch]$SkipSkill,
    [switch]$SkipLegacyCleanup,
    [switch]$NonInteractive,
    [string]$AutoUpdateTaskName = 'HaloMcpAtlassian-AutoUpdate'
)

$ErrorActionPreference = 'Stop'

# ---- Paths ------------------------------------------------------------------
$RepoRoot       = Split-Path -Parent $PSScriptRoot
$WrapperSrc     = Join-Path $RepoRoot 'wrapper\mcp-halo-atlassian.ps1'
$HelperSrc      = Join-Path $RepoRoot 'wrapper\CredentialStore.ps1'
$SkillSrc       = Join-Path $RepoRoot 'skills\halo-atlassian'
$WrapperDst     = Join-Path $DeployRoot 'mcp-halo-atlassian.ps1'
$HelperDst      = Join-Path $DeployRoot 'CredentialStore.ps1'
$SkillDst       = Join-Path $SkillRoot 'halo-atlassian'
$ConfigDir      = Join-Path $env:USERPROFILE '.copilot'
$ConfigPath     = Join-Path $ConfigDir 'mcp-config.json'

# Legacy deploy paths to detect + offer to clean during migration. A user
# coming from the original D:\CopilotScripts layout has these orphans after
# the default flip; the installer should not leave stale copies behind that
# could be picked up by an out-of-date mcp-config entry.
$LegacyDeployRoots = @(
    'D:\CopilotScripts'
)

if (-not (Test-Path $WrapperSrc)) { throw "wrapper source missing: $WrapperSrc" }
if (-not (Test-Path $HelperSrc))  { throw "helper source missing: $HelperSrc" }

function Write-Step  ([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok    ([string]$msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2 ([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Dry   ([string]$msg) { Write-Host "    [DRYRUN] $msg" -ForegroundColor DarkGray }

# Idempotency banner: detect prior install before any user prompts so a
# re-run is announced as a token rotation, not a fresh install.
$priorInstall = (Test-Path $WrapperDst) -or (Test-Path $TenantConfigPath)
if ($priorInstall) {
    Write-Host '==> Detected prior install — running in rotate/refresh mode.' -ForegroundColor Cyan
    if (Test-Path $WrapperDst)       { Write-Ok "wrapper present: $WrapperDst" }
    if (Test-Path $TenantConfigPath) { Write-Ok "tenant config present: $TenantConfigPath" }
}
else {
    Write-Host '==> Fresh install.' -ForegroundColor Cyan
}

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
    if ($NonInteractive) { throw '-NonInteractive set but -Email not provided.' }
    $Email = Read-Host 'Atlassian email (e.g. you@your-org.com)'
}
if (-not $Email) { throw 'Email is required.' }

if (-not $Token) {
    if ($NonInteractive) { throw '-NonInteractive set but -Token not provided.' }
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

if (-not $JiraUrl) {
    if ($NonInteractive) { throw '-NonInteractive set but -JiraUrl not provided.' }
    $JiraUrl = Read-Host 'Atlassian Jira base URL (e.g. https://your-tenant.atlassian.net)'
}
if (-not $JiraUrl) { throw 'Jira URL is required.' }
$JiraUrl = $JiraUrl.TrimEnd('/')

if (-not $ConfluenceUrl) {
    $defaultConfluence = "$JiraUrl/wiki"
    if ($NonInteractive) {
        $ConfluenceUrl = $defaultConfluence
    }
    else {
        $resp = Read-Host "Atlassian Confluence base URL [$defaultConfluence]"
        $ConfluenceUrl = if ([string]::IsNullOrWhiteSpace($resp)) { $defaultConfluence } else { $resp.TrimEnd('/') }
    }
}

# Mirror src/halo_mcp_atlassian/config.py validation so users see the error
# at install time instead of getting cryptic ConfigError on first launch.
function Test-AtlassianUrl {
    param([string]$Url, [string]$Label)
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "$Label URL is not a valid absolute URL: '$Url'"
    }
    if ($uri.Scheme -ne 'https') {
        throw "$Label URL must use https:// (got '$($uri.Scheme)://...')"
    }
    if (-not $uri.Host.EndsWith('.atlassian.net')) {
        throw "$Label URL must end in .atlassian.net (got host '$($uri.Host)')"
    }
}
Test-AtlassianUrl -Url $JiraUrl       -Label 'Jira'
Test-AtlassianUrl -Url $ConfluenceUrl -Label 'Confluence'

# ---- 2b. Pre-flight summary -------------------------------------------------
# Show every side-effecting target before we touch anything. In interactive
# mode wait for Enter; -NonInteractive / -DryRun skip the pause.
Write-Host ''
Write-Host '==> Pre-flight summary' -ForegroundColor Cyan
Write-Host ("    Mode             : {0}" -f $(if ($priorInstall) { 'rotate / refresh' } else { 'fresh install' }))
Write-Host ("    Deploy root      : {0}" -f $DeployRoot)
Write-Host ("    Tenant config    : {0}" -f $TenantConfigPath)
Write-Host ("    Jira URL         : {0}" -f $JiraUrl)
Write-Host ("    Confluence URL   : {0}" -f $ConfluenceUrl)
Write-Host ("    mcp-config       : {0}" -f $ConfigPath)
Write-Host ("    Atlassian email  : {0}" -f $Email)
Write-Host ("    Scheduled task   : {0}" -f $(if ($SkipAutoUpdate) { '(skipped)' } else { $AutoUpdateTaskName + ' (weekly Mon 03:30)' }))
Write-Host ''
if (-not $DryRun -and -not $NonInteractive) {
    $null = Read-Host 'Press Enter to continue, Ctrl-C to abort'
}

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

# ---- 3b. Write tenant config (non-secret, per-user) -------------------------
Write-Step "Writing tenant config to $TenantConfigPath"
if ($DryRun) {
    Write-Dry "{`"jira_url`": `"$JiraUrl`", `"confluence_url`": `"$ConfluenceUrl`"} -> $TenantConfigPath"
}
else {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $TenantConfigPath) -Force | Out-Null
        $tenantObj = [ordered]@{ jira_url = $JiraUrl; confluence_url = $ConfluenceUrl }
        ($tenantObj | ConvertTo-Json) | Set-Content -Path $TenantConfigPath -Encoding UTF8
        Write-Ok "tenant config: jira=$JiraUrl confluence=$ConfluenceUrl"
    }
    catch {
        Write-Error "Failed to write tenant config: $_"
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
    Write-Dry "ensure mcpServers.halo-atlassian -> $WrapperDst (preserves other servers; backs up existing mcp-config.json to .bak)"
}
else {
    try {
        $existingHalo = $null
        $siblingNames = @()
        if (Test-Path $ConfigPath) {
            # Defensive backup before any mutation so a parser/encoding glitch
            # can never strand a user's curated mcp-config.json.
            $backupPath = "$ConfigPath.bak"
            Copy-Item $ConfigPath $backupPath -Force
            Write-Ok "backup: $backupPath"

            $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            if (-not $cfg) { $cfg = [ordered]@{} }
            if ($cfg.Contains('mcpServers') -and $cfg['mcpServers']) {
                $existingHalo = $cfg['mcpServers']['halo-atlassian']
                $siblingNames = @($cfg['mcpServers'].Keys | Where-Object { $_ -ne 'halo-atlassian' })
            }
        }
        else {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
            $cfg = [ordered]@{}
        }

        if (-not $cfg.Contains('mcpServers')) { $cfg['mcpServers'] = [ordered]@{} }
        if ($existingHalo) {
            Write-Warn2 "overwriting existing 'halo-atlassian' MCP entry (backup at .bak)"
        }
        $cfg['mcpServers']['halo-atlassian'] = $desiredEntry

        ($cfg | ConvertTo-Json -Depth 10) | Set-Content $ConfigPath -Encoding UTF8
        if ($siblingNames.Count -gt 0) {
            $list = ($siblingNames | Sort-Object) -join ', '
            Write-Ok "mcp-config.json updated; preserved $($siblingNames.Count) other server(s): $list"
        } else {
            Write-Ok "mcp-config.json updated (no other servers present)"
        }
    }
    catch {
        Write-Error "Failed to update mcp-config.json: $_"
        exit 3
    }
}

# ---- 5b. Install / refresh Copilot CLI skill -------------------------------
if (-not $SkipSkill) {
    Write-Step "Installing Copilot CLI skill to $SkillDst"
    if (-not (Test-Path $SkillSrc)) {
        Write-Warn2 "skill source missing at $SkillSrc; skipping (use -SkipSkill to silence this)"
    }
    elseif ($DryRun) {
        Write-Dry "Copy-Item -Recurse $SkillSrc -> $SkillDst"
    }
    else {
        try {
            New-Item -ItemType Directory -Path $SkillRoot -Force | Out-Null
            if (Test-Path $SkillDst) {
                # Refresh in place so any user-local changes outside the
                # repo-tracked files are wiped; this matches wrapper deploy.
                Remove-Item -Recurse -Force $SkillDst
            }
            Copy-Item -Recurse $SkillSrc $SkillDst -Force
            Write-Ok "skill deployed: $SkillDst (run /skills in Copilot to toggle on)"
        }
        catch {
            Write-Warn2 "skill install failed: $_  (continuing; install manually from skills\halo-atlassian)"
        }
    }
}

# ---- 5c. Detect + offer to clean legacy D:\CopilotScripts deploy -----------
# Users who installed prior to the deploy-root flip have orphaned wrapper +
# helper at the old path. They're not used by anything any more (the new
# mcp-config entry points at $WrapperDst above) but leaving them around is
# confusing. Detect, list, prompt — or auto-skip with -SkipLegacyCleanup.
if (-not $SkipLegacyCleanup) {
    $legacyHits = @()
    foreach ($root in $LegacyDeployRoots) {
        if ([string]::Equals($root, $DeployRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($leaf in @('mcp-halo-atlassian.ps1','CredentialStore.ps1')) {
            $candidate = Join-Path $root $leaf
            if (Test-Path $candidate) { $legacyHits += $candidate }
        }
    }
    if ($legacyHits.Count -gt 0) {
        Write-Step 'Detected legacy install files (from a pre-LOCALAPPDATA deploy)'
        $legacyHits | ForEach-Object { Write-Warn2 "legacy: $_" }
        $doRemove = $false
        if ($DryRun) {
            Write-Dry "Remove-Item on $($legacyHits.Count) legacy file(s)"
        }
        elseif ($NonInteractive) {
            Write-Warn2 'NonInteractive mode; leaving legacy files in place. Re-run with -SkipLegacyCleanup:$false interactively or delete manually.'
        }
        else {
            $resp = Read-Host "Remove these $($legacyHits.Count) legacy file(s)? They are no longer referenced by mcp-config. [y/N]"
            $doRemove = ($resp -match '^[yY]')
        }
        if ($doRemove) {
            foreach ($f in $legacyHits) {
                try { Remove-Item -Force $f; Write-Ok "removed: $f" }
                catch { Write-Warn2 "could not remove $f : $_" }
            }
        }
        elseif (-not $DryRun -and -not $NonInteractive) {
            Write-Warn2 'Leaving legacy files in place. Re-run any time to clean.'
        }
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
            '-e',"ATLASSIAN_JIRA_URL=$JiraUrl",
            '-e',"ATLASSIAN_CONFLUENCE_URL=$ConfluenceUrl",
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

# ---- 8. Register weekly auto-update scheduled task --------------------------
$UpdateScript = Join-Path $RepoRoot 'setup\Update-HaloAtlassianMcp.ps1'
if ($SkipAutoUpdate) {
    Write-Warn2 'SkipAutoUpdate set; not registering scheduled task.'
}
elseif (-not (Test-Path $UpdateScript)) {
    Write-Warn2 "Update script missing ($UpdateScript); skipping auto-update task."
}
else {
    Write-Step "Registering weekly auto-update task: $AutoUpdateTaskName"
    if ($DryRun) {
        Write-Dry "Register-ScheduledTask -TaskName $AutoUpdateTaskName -Action 'pwsh -File $UpdateScript' -Trigger 'Weekly Mon 03:30'"
    }
    else {
        try {
            $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
            $action  = New-ScheduledTaskAction `
                -Execute $pwshExe `
                -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`" -RepoRoot `"$RepoRoot`" -DeployRoot `"$DeployRoot`"")
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 3:30am
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
                -MultipleInstances IgnoreNew
            $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

            Register-ScheduledTask `
                -TaskName $AutoUpdateTaskName `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description 'Weekly git pull + docker pull for halo-mcp-atlassian. Keeps the pinned image and wrapper fresh without user action.' `
                -Force | Out-Null
            Write-Ok "scheduled task registered (Mondays 03:30 local; logs at %LOCALAPPDATA%\HaloMcp\update.log)"
            Write-Ok "to remove: Unregister-ScheduledTask -TaskName $AutoUpdateTaskName -Confirm:`$false"
        }
        catch {
            Write-Warn2 "Could not register scheduled task: $($_.Exception.Message)"
            Write-Warn2 "Run setup\Update-HaloAtlassianMcp.ps1 manually, or schedule it yourself."
        }
    }
}

# ---- 9. Next steps ----------------------------------------------------------
Write-Host ''
Write-Host '==> Done.' -ForegroundColor Green
Write-Host ''

# Next-run for the auto-update task (skipped on DryRun / SkipAutoUpdate).
if (-not $DryRun -and -not $SkipAutoUpdate) {
    try {
        $info = Get-ScheduledTaskInfo -TaskName $AutoUpdateTaskName -ErrorAction Stop
        if ($info.NextRunTime) {
            Write-Host ("Auto-update next run: {0:yyyy-MM-dd HH:mm} (local)" -f $info.NextRunTime) -ForegroundColor Cyan
        }
    } catch { } # task didn't register, already warned above
}

Write-Host ''
Write-Host 'Next:'
if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    Write-Host '  1. npm install -g @github/copilot'
    Write-Host '  2. copilot'
}
else {
    Write-Host '  1. copilot'
}
Write-Host '  -. In session:  /tools         (should list halo-atlassian-* tools)'
Write-Host ''
Write-Host 'To rotate the token: re-run this script (idempotent).'
Write-Host 'To inspect the credential: cmdkey /list:halo-atlassian:api-token'

