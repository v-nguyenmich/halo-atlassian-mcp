# Self-contained smoke tests for the Windows wrapper bits. No Pester required.
# Exits 0 on success, non-zero on first failure. Skips on non-Windows.
#
# Run:
#   pwsh -NoProfile -File tests\test_wrapper.ps1

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host 'Wrapper tests are Windows-only; skipping.' -ForegroundColor Yellow
    exit 0
}

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$HelperPath = Join-Path $RepoRoot 'wrapper\CredentialStore.ps1'
$Installer  = Join-Path $RepoRoot 'setup\Install-HaloAtlassianMcp.ps1'

$failures = 0
function Assert([scriptblock]$check, [string]$desc) {
    try {
        $ok = & $check
        if ($ok) { Write-Host "  PASS  $desc" -ForegroundColor Green }
        else     { Write-Host "  FAIL  $desc" -ForegroundColor Red; $script:failures++ }
    }
    catch {
        Write-Host "  FAIL  $desc  ($_)" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host '== CredentialStore helper ==' -ForegroundColor Cyan
Assert { Test-Path $HelperPath } 'helper file exists'
. $HelperPath
Assert { Get-Command Get-HaloAtlassianCredential -ErrorAction SilentlyContinue } 'Get-* exported'
Assert { Get-Command Set-HaloAtlassianCredential -ErrorAction SilentlyContinue } 'Set-* exported'
Assert { Get-Command Remove-HaloAtlassianCredential -ErrorAction SilentlyContinue } 'Remove-* exported'

# Round-trip against a *temporary alternate target* so we never touch the
# user's real halo-atlassian:api-token credential.
$realTarget = (Get-Variable HaloCredTarget -Scope Script -ValueOnly)
Set-Variable -Name HaloCredTarget -Value 'halo-atlassian:test-roundtrip' -Scope Script -Force
try {
    # Pre-clean
    try { [void](Remove-HaloAtlassianCredential) } catch { }

    Assert { $null -eq (Get-HaloAtlassianCredential) } 'absent credential returns $null'

    $testEmail = 'roundtrip@example.com'
    $testToken = 'sk-éñ-' + ([guid]::NewGuid().ToString('N'))
    Set-HaloAtlassianCredential -Email $testEmail -Token $testToken
    $back = Get-HaloAtlassianCredential
    Assert { $back.Email -eq $testEmail }  'email round-trips'
    Assert { $back.Token -eq $testToken }  'token round-trips (incl. unicode)'

    Assert { (Remove-HaloAtlassianCredential) -eq $true } 'delete returns true on success'
    Assert { $null -eq (Get-HaloAtlassianCredential) }    'credential gone after delete'
    Assert { (Remove-HaloAtlassianCredential) -eq $false } 'delete on missing returns false'
}
finally {
    Set-Variable -Name HaloCredTarget -Value $realTarget -Scope Script -Force
}

Write-Host ''
Write-Host '== Installer DryRun ==' -ForegroundColor Cyan
Assert { Test-Path $Installer } 'installer file exists'

$tmpDeploy = Join-Path $env:TEMP ("halo-mcp-install-test-" + [guid]::NewGuid().ToString('N'))
try {
    $out = & pwsh -NoProfile -File $Installer `
        -Email 'dry@example.com' -Token 'dry-token' `
        -DeployRoot $tmpDeploy -DryRun 2>&1
    $exit = $LASTEXITCODE
    Assert { $exit -eq 0 } "installer -DryRun exits 0 (got $exit)"
    Assert { ($out -join "`n") -match 'DRYRUN.*Set-HaloAtlassianCredential' } 'installer logs credential write step'
    Assert { ($out -join "`n") -match 'DRYRUN.*Copy-Item.*mcp-halo-atlassian\.ps1' } 'installer logs wrapper copy step'
    Assert { ($out -join "`n") -match 'DRYRUN.*docker pull' } 'installer logs docker pull step'
    Assert { ($out -join "`n") -match 'DRYRUN.*Register-ScheduledTask' } 'installer logs auto-update task registration'
    Assert { -not (Test-Path $tmpDeploy) } 'DryRun did not create deploy dir'
}
finally {
    if (Test-Path $tmpDeploy) { Remove-Item $tmpDeploy -Recurse -Force }
}

# --- Update-HaloAtlassianMcp.ps1 script sanity -------------------------------
Write-Host '== Update script ==' -ForegroundColor Cyan
$Updater = Join-Path $RepoRoot 'setup\Update-HaloAtlassianMcp.ps1'
Assert { Test-Path $Updater } 'updater file exists'
Assert {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Updater, [ref]$null, [ref]$errors)
    $errors.Count -eq 0
} 'updater parses without syntax errors'
Assert {
    (Get-Content $Updater -Raw) -match '\.SYNOPSIS\s*\r?\n\s*Pulls the latest'
} 'updater has synopsis'

Write-Host ''
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
