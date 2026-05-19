# Uninstaller for the halo-mcp-atlassian MCP server.
#
# Symmetric with Install-HaloAtlassianMcp.ps1. Removes everything the
# installer wrote: deploy folder, mcp-config halo-atlassian entry,
# scheduled task, credential, and tenant config.
#
# Usage:
#   .\setup\Uninstall-HaloAtlassianMcp.ps1              # interactive
#   .\setup\Uninstall-HaloAtlassianMcp.ps1 -DryRun      # show actions only
#   .\setup\Uninstall-HaloAtlassianMcp.ps1 -NonInteractive  # no prompts
#
# Exit codes:
#   0 = success or DryRun completed
#   1 = user declined confirmation

[CmdletBinding()]
param(
    [string]$DeployRoot         = (Join-Path $env:LOCALAPPDATA 'Programs\halo-mcp-atlassian'),
    [string]$TenantConfigPath   = (Join-Path $env:USERPROFILE '.halo-atlassian.json'),
    [string]$McpConfigPath      = (Join-Path $env:USERPROFILE '.copilot\mcp-config.json'),
    [string]$SkillPath          = (Join-Path $env:USERPROFILE '.copilot\skills\halo-atlassian'),
    [string]$AutoUpdateTaskName = 'HaloMcpAtlassian-AutoUpdate',
    [string]$CredentialTarget   = 'halo-atlassian:api-token',
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$KeepCredential,
    [switch]$KeepTenantConfig,
    [switch]$KeepSkill
)

$ErrorActionPreference = 'Stop'

function Write-Action([string]$Verb, [string]$What) {
    $prefix = if ($DryRun) { '[DRYRUN] ' } else { '' }
    Write-Host ("{0}{1,-9} {2}" -f $prefix, $Verb, $What)
}

# ---- Pre-flight summary -----------------------------------------------------
Write-Host ''
Write-Host '=== halo-mcp-atlassian uninstaller ===' -ForegroundColor Cyan
Write-Host ("  deploy root         : {0}" -f $DeployRoot)
Write-Host ("  mcp-config path     : {0}" -f $McpConfigPath)
Write-Host ("  tenant config       : {0}{1}" -f $TenantConfigPath, $(if ($KeepTenantConfig) { ' (KEEP)' } else { '' }))
Write-Host ("  skill path          : {0}{1}" -f $SkillPath, $(if ($KeepSkill) { ' (KEEP)' } else { '' }))
Write-Host ("  scheduled task      : {0}" -f $AutoUpdateTaskName)
Write-Host ("  credential target   : {0}{1}" -f $CredentialTarget, $(if ($KeepCredential) { ' (KEEP)' } else { '' }))
Write-Host ''

if (-not $DryRun -and -not $NonInteractive) {
    $resp = Read-Host 'Proceed with removal? [y/N]'
    if ($resp -notmatch '^[yY]') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 1
    }
}

$summary = [ordered]@{}

# ---- 1. Scheduled task ------------------------------------------------------
try {
    $task = Get-ScheduledTask -TaskName $AutoUpdateTaskName -ErrorAction Stop
    Write-Action 'remove' ("scheduled task '{0}'" -f $AutoUpdateTaskName)
    if (-not $DryRun) {
        Unregister-ScheduledTask -TaskName $AutoUpdateTaskName -Confirm:$false
    }
    $summary['scheduled_task'] = 'removed'
} catch {
    Write-Action 'skip' ("scheduled task '{0}' not registered" -f $AutoUpdateTaskName)
    $summary['scheduled_task'] = 'absent'
}

# ---- 2. mcp-config halo-atlassian entry ------------------------------------
if (Test-Path $McpConfigPath) {
    $raw = Get-Content $McpConfigPath -Raw
    $cfg = $null
    try { $cfg = $raw | ConvertFrom-Json -AsHashtable } catch { }
    if ($null -ne $cfg -and $cfg.ContainsKey('mcpServers') -and $cfg.mcpServers.ContainsKey('halo-atlassian')) {
        Write-Action 'remove' ("mcp-config entry 'halo-atlassian' (backup -> {0}.bak)" -f $McpConfigPath)
        if (-not $DryRun) {
            Copy-Item $McpConfigPath ("$McpConfigPath.bak") -Force
            [void]$cfg.mcpServers.Remove('halo-atlassian')
            $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $McpConfigPath -Encoding UTF8
        }
        $summary['mcp_config'] = 'entry_removed'
    } else {
        Write-Action 'skip' "mcp-config has no 'halo-atlassian' entry"
        $summary['mcp_config'] = 'absent'
    }
} else {
    Write-Action 'skip' "mcp-config.json not present"
    $summary['mcp_config'] = 'absent'
}

# ---- 3. Deploy folder -------------------------------------------------------
if (Test-Path $DeployRoot) {
    Write-Action 'remove' ("deploy folder '{0}'" -f $DeployRoot)
    if (-not $DryRun) {
        Remove-Item -Recurse -Force $DeployRoot
    }
    $summary['deploy_root'] = 'removed'
} else {
    Write-Action 'skip' ("deploy folder '{0}' does not exist" -f $DeployRoot)
    $summary['deploy_root'] = 'absent'
}

# ---- 4. Tenant config -------------------------------------------------------
if (-not $KeepTenantConfig) {
    if (Test-Path $TenantConfigPath) {
        Write-Action 'remove' ("tenant config '{0}'" -f $TenantConfigPath)
        if (-not $DryRun) {
            Remove-Item -Force $TenantConfigPath
        }
        $summary['tenant_config'] = 'removed'
    } else {
        Write-Action 'skip' "tenant config does not exist"
        $summary['tenant_config'] = 'absent'
    }
} else {
    Write-Action 'keep' "tenant config (KeepTenantConfig)"
    $summary['tenant_config'] = 'kept'
}

# ---- 4b. Copilot CLI skill --------------------------------------------------
if (-not $KeepSkill) {
    if (Test-Path $SkillPath) {
        Write-Action 'remove' ("skill '{0}'" -f $SkillPath)
        if (-not $DryRun) {
            Remove-Item -Recurse -Force $SkillPath
        }
        $summary['skill'] = 'removed'
    } else {
        Write-Action 'skip' "skill does not exist"
        $summary['skill'] = 'absent'
    }
} else {
    Write-Action 'keep' "skill (KeepSkill)"
    $summary['skill'] = 'kept'
}

# ---- 5. Credential ----------------------------------------------------------
if (-not $KeepCredential) {
    Write-Action 'remove' ("credential '{0}'" -f $CredentialTarget)
    if (-not $DryRun) {
        $out = & cmdkey "/delete:$CredentialTarget" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $summary['credential'] = 'removed'
        } else {
            Write-Host ("  (cmdkey: {0})" -f ($out -join ' ')) -ForegroundColor DarkGray
            $summary['credential'] = 'absent_or_failed'
        }
    } else {
        $summary['credential'] = 'would_remove'
    }
} else {
    Write-Action 'keep' "credential (KeepCredential)"
    $summary['credential'] = 'kept'
}

# ---- Summary ----------------------------------------------------------------
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$summary.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-16} : {1}" -f $_.Key, $_.Value) }
Write-Host ''
if ($DryRun) {
    Write-Host 'DryRun complete. Re-run without -DryRun to apply.' -ForegroundColor Yellow
} else {
    Write-Host 'Uninstall complete.' -ForegroundColor Green
}
exit 0
