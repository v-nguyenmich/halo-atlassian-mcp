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
$tmpTenant = Join-Path $env:TEMP ("halo-tenant-" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $out = & pwsh -NoProfile -File $Installer `
        -Email 'dry@example.com' -Token 'dry-token' `
        -JiraUrl 'https://t.example.com' -ConfluenceUrl 'https://t.example.com/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    $exit = $LASTEXITCODE
    Assert { $exit -eq 0 } "installer -DryRun exits 0 (got $exit)"
    Assert { ($out -join "`n") -match 'DRYRUN.*Set-HaloAtlassianCredential' } 'installer logs credential write step'
    Assert { ($out -join "`n") -match 'DRYRUN.*jira_url.*t\.example\.com' } 'installer logs tenant config write'
    Assert { ($out -join "`n") -match 'DRYRUN.*Copy-Item.*mcp-halo-atlassian\.ps1' } 'installer logs wrapper copy step'
    Assert { ($out -join "`n") -match 'DRYRUN.*docker pull' } 'installer logs docker pull step'
    Assert { ($out -join "`n") -match 'DRYRUN.*Register-ScheduledTask' } 'installer logs auto-update task registration'
    Assert { -not (Test-Path $tmpDeploy) } 'DryRun did not create deploy dir'
    Assert { -not (Test-Path $tmpTenant) } 'DryRun did not write tenant config'
}
finally {
    if (Test-Path $tmpDeploy) { Remove-Item $tmpDeploy -Recurse -Force }
    if (Test-Path $tmpTenant) { Remove-Item $tmpTenant -Force }
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

# --- bump-wrapper-digest.sh: rewrite is idempotent + correct -----------------
Write-Host ''
Write-Host '== Bump wrapper digest script ==' -ForegroundColor Cyan
$BumpSh = Join-Path $RepoRoot 'scripts\bump-wrapper-digest.sh'
Assert { Test-Path $BumpSh } 'bump script exists'
Assert { (Get-Content $BumpSh -Raw) -match 'NEW_DIGEST' } 'bump script declares NEW_DIGEST env'

# Locally execute the Python rewrite portion against a copy of the wrapper.
$tmpWrap = Join-Path $env:TEMP ("bump-test-" + [guid]::NewGuid().ToString('N') + ".ps1")
Copy-Item (Join-Path $RepoRoot 'wrapper\mcp-halo-atlassian.ps1') $tmpWrap
try {
    $newRef = 'ghcr.io/test/img@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    $script = @'
import re, sys, pathlib
path, new_ref, short = sys.argv[1:]
text = pathlib.Path(path).read_text(encoding="utf-8")
m = re.search(r"^\$DefaultImage\s*=\s*'([^']+)'", text, re.MULTILINE)
if not m: sys.exit(10)
old = m.group(1)
print(old)
if old == new_ref: sys.exit(2)
text, n = re.subn(r"^(\$DefaultImage\s*=\s*')[^']+(')(\s*#[^\r\n]*)?",
    lambda mo: f"{mo.group(1)}{new_ref}{mo.group(2)}  # auto-bumped from {short}",
    text, count=1, flags=re.MULTILINE)
if n != 1: sys.exit(11)
text, n = re.subn(r"^(\$PreviousImage\s*=\s*\$env:HALO_MCP_PREV_IMAGE\s*;\s*if\s*\(-not\s*\$PreviousImage\)\s*\{\s*\$PreviousImage\s*=\s*')[^']+(')",
    lambda mo: f"{mo.group(1)}{old}{mo.group(2)}",
    text, count=1, flags=re.MULTILINE)
if n != 1: sys.exit(12)
pathlib.Path(path).write_text(text, encoding="utf-8")
'@
    $scriptFile = [IO.Path]::ChangeExtension($tmpWrap, '.py')
    Set-Content -Path $scriptFile -Value $script -Encoding UTF8
    $oldDigest = (& uv run python $scriptFile $tmpWrap $newRef 'cafef00' | Select-Object -First 1).Trim()
    $rc = $LASTEXITCODE
    Assert { $rc -eq 0 } "first rewrite exits 0 (got $rc)"
    Assert { ((Select-String -Path $tmpWrap -Pattern '^\$DefaultImage' | Select-Object -First 1).Line) -match [regex]::Escape($newRef) } 'DefaultImage updated'
    Assert { ((Select-String -Path $tmpWrap -Pattern '^\$PreviousImage' | Select-Object -First 1).Line) -match [regex]::Escape($oldDigest) } 'PreviousImage demoted to old default'
    Assert { ((Select-String -Path $tmpWrap -Pattern '^\$DefaultImage' | Select-Object -First 1).Line) -match 'auto-bumped from cafef00' } 'auto-bump comment present'
    # Second run with same digest is a no-op (exit 2 means SAME).
    & uv run python $scriptFile $tmpWrap $newRef 'cafef00' *> $null
    Assert { $LASTEXITCODE -eq 2 } "second rewrite is no-op (exit 2 for SAME, got $LASTEXITCODE)"
    Remove-Item $scriptFile -Force
}
finally {
    if (Test-Path $tmpWrap) { Remove-Item $tmpWrap -Force }
}

# --- Wrapper tenant-URL resolution ------------------------------------------
Write-Host ''
Write-Host '== Wrapper tenant config ==' -ForegroundColor Cyan
$Wrapper = Join-Path $RepoRoot 'wrapper\mcp-halo-atlassian.ps1'
Assert {
    $text = Get-Content $Wrapper -Raw
    # Must NOT have a hardcoded tenant URL anywhere.
    (-not ($text -match '343industries\.atlassian\.net')) -and
    (-not ($text -match 'halostudios\.com'))
} 'wrapper has no hardcoded tenant URLs'
Assert {
    (Get-Content $Wrapper -Raw) -match 'HALO_MCP_TENANT_CONFIG'
} 'wrapper reads HALO_MCP_TENANT_CONFIG env override'
Assert {
    (Get-Content $Wrapper -Raw) -match '\.halo-atlassian\.json'
} 'wrapper falls back to ~/.halo-atlassian.json'

Write-Host ''
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
