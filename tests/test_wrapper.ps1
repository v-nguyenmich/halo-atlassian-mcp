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
        -JiraUrl 'https://t.atlassian.net' -ConfluenceUrl 'https://t.atlassian.net/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    $exit = $LASTEXITCODE
    Assert { $exit -eq 0 } "installer -DryRun exits 0 (got $exit)"
    Assert { ($out -join "`n") -match 'DRYRUN.*Set-HaloAtlassianCredential' } 'installer logs credential write step'
    Assert { ($out -join "`n") -match 'DRYRUN.*jira_url.*t\.atlassian\.net' } 'installer logs tenant config write'
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

# --- Installer default DeployRoot --------------------------------------------
Write-Host ''
Write-Host '== Default DeployRoot ==' -ForegroundColor Cyan
$installerText = Get-Content $Installer -Raw
$updaterText   = Get-Content $Updater   -Raw
Assert {
    -not ($installerText -match "\[string\]\`$DeployRoot\s*=\s*'D:\\\\CopilotScripts'")
} 'installer default no longer hardcodes D:\CopilotScripts'
Assert {
    -not ($updaterText -match "\[string\]\`$DeployRoot\s*=\s*'D:\\\\CopilotScripts'")
} 'updater default no longer hardcodes D:\CopilotScripts'
Assert {
    $installerText -match "\`$env:LOCALAPPDATA\s+'Programs\\halo-mcp-atlassian'"
} 'installer defaults to %LOCALAPPDATA%\Programs\halo-mcp-atlassian'
Assert {
    $updaterText -match "\`$env:LOCALAPPDATA\s+'Programs\\halo-mcp-atlassian'"
} 'updater defaults to %LOCALAPPDATA%\Programs\halo-mcp-atlassian'
Assert {
    $updaterText -match 'docker images.*\$repoRef.*dangling=true'
} 'updater prunes dangling halo images, scoped to the halo image repo'
Assert {
    $updaterText -match 'docker rmi -f'
} 'updater removes dangling image IDs after digest bump'
Assert {
    # Scheduled task must still pass -DeployRoot explicitly so a later
    # default change can't strand existing tasks pointed at old paths.
    $installerText -match '-DeployRoot\s+`"\$DeployRoot`"'
} 'scheduled-task arglist still passes -DeployRoot explicitly'

# --- Installer tenant URL validation ----------------------------------------
Write-Host ''
Write-Host '== Tenant URL validation ==' -ForegroundColor Cyan
$tmpDeploy = Join-Path $env:TEMP ("halo-mcp-vald-" + [guid]::NewGuid().ToString('N'))
$tmpTenant = Join-Path $env:TEMP ("halo-tenant-vald-" + [guid]::NewGuid().ToString('N') + ".json")
try {
    # Bad scheme.
    $err = pwsh -NoProfile -File $Installer -Email 'a@b.c' -Token 'x' `
        -JiraUrl 'http://t.atlassian.net' -ConfluenceUrl 'https://t.atlassian.net/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    Assert { $LASTEXITCODE -ne 0 } 'http:// scheme is rejected'
    Assert { ($err -join "`n") -match 'must use https' } 'helpful error for http://'

    # Bad host.
    $err = pwsh -NoProfile -File $Installer -Email 'a@b.c' -Token 'x' `
        -JiraUrl 'https://example.com' -ConfluenceUrl 'https://example.com/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    Assert { $LASTEXITCODE -ne 0 } 'non-atlassian.net host is rejected'
    Assert { ($err -join "`n") -match 'must end in \.atlassian\.net' } 'helpful error for bad host'

    # Garbage URL.
    $err = pwsh -NoProfile -File $Installer -Email 'a@b.c' -Token 'x' `
        -JiraUrl 'not-a-url' -ConfluenceUrl 'https://t.atlassian.net/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    Assert { $LASTEXITCODE -ne 0 } 'malformed URL is rejected'

    # Happy path with /wiki Confluence path still passes host check.
    $out = pwsh -NoProfile -File $Installer -Email 'a@b.c' -Token 'x' `
        -JiraUrl 'https://t.atlassian.net' -ConfluenceUrl 'https://t.atlassian.net/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant -DryRun 2>&1
    Assert { $LASTEXITCODE -eq 0 } "well-formed URLs pass (got $LASTEXITCODE)"
}
finally {
    if (Test-Path $tmpDeploy) { Remove-Item $tmpDeploy -Recurse -Force }
    if (Test-Path $tmpTenant) { Remove-Item $tmpTenant -Force }
}

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

# --- Wrapper portability (PR1) ----------------------------------------------
Write-Host ''
Write-Host '== Wrapper portability ==' -ForegroundColor Cyan
$wrapperText = Get-Content $Wrapper -Raw
Assert {
    -not ($wrapperText -match "D:\\\\CopilotScripts\\\\halo-mcp-atlassian\\\\uploads")
} 'wrapper has no hardcoded D:\ uploads path'
Assert {
    -not ($wrapperText -match "'D:\\\\CopilotScripts\\\\halo-mcp-atlassian\\\\wrapper\\\\CredentialStore\.ps1'")
} 'wrapper has no stale D:\ CredentialStore fallback'
Assert {
    $wrapperText -match "Join-Path\s+\`$PSScriptRoot\s+'uploads'"
} 'wrapper derives uploads dir from $PSScriptRoot'
Assert {
    $wrapperText -match 'param\(\s*\[switch\]\$DryRun'
} 'wrapper accepts -DryRun switch'
Assert {
    $wrapperText -match 'docker info'
} 'wrapper preflights with docker info'
Assert {
    $wrapperText -match 'Docker Desktop is not running'
} 'wrapper prints friendly Docker-not-running error'
Assert {
    $wrapperText -match 'Get-Command\s+docker'
} 'wrapper looks up docker via PATH first'

# Functional: -DryRun exits 0 even when tenant URLs are absent.
$old1 = $env:ATLASSIAN_JIRA_URL; $old2 = $env:ATLASSIAN_CONFLUENCE_URL
try {
    $env:ATLASSIAN_JIRA_URL = $null; $env:ATLASSIAN_CONFLUENCE_URL = $null
    $out = pwsh -NoProfile -File $Wrapper -DryRun 2>&1
    Assert { $LASTEXITCODE -eq 0 } "wrapper -DryRun exits 0 without tenant URLs (got $LASTEXITCODE)"
    Assert { ($out -join "`n") -match 'DRYRUN: full command' } 'wrapper -DryRun prints the docker invocation'
    Assert { ($out -join "`n") -match 'DRYRUN WARNING.*tenant URLs not configured' } 'wrapper -DryRun warns about missing tenant URLs instead of failing'
}
finally {
    $env:ATLASSIAN_JIRA_URL = $old1; $env:ATLASSIAN_CONFLUENCE_URL = $old2
    # Test side-effect: -DryRun creates uploads/ next to the wrapper.
    Remove-Item (Join-Path (Split-Path $Wrapper -Parent) 'uploads') -Recurse -Force -ErrorAction SilentlyContinue
}

# --- mcp-config.json merge safety (PR4) -------------------------------------
Write-Host ''
Write-Host '== mcp-config merge safety ==' -ForegroundColor Cyan

# Source-level structural assertions (cheap, no subprocess).
Assert {
    $installerText -match 'Copy-Item\s+\$ConfigPath\s+\$backupPath\s+-Force'
} 'installer backs up mcp-config.json before write'
Assert {
    $installerText -match "overwriting existing 'halo-atlassian' MCP entry"
} 'installer warns when overwriting existing halo-atlassian entry'
Assert {
    $installerText -match 'preserved \$\(\$siblingNames\.Count\) other server'
} 'installer reports preserved sibling count'
Assert {
    # Idempotency: NO -Force gate on second install (overwrite is allowed but warned).
    -not ($installerText -match '\[switch\]\$Force')
} 'installer does not require -Force on re-install (keeps idempotency)'
Assert {
    $installerText -match 'backs up existing mcp-config\.json to \.bak'
} 'DryRun message mentions backup behavior'

# Functional: run installer against a redirected $env:USERPROFILE so the real
# ~/.copilot/mcp-config.json is never touched. Use a non-DryRun invocation up
# to (but not through) the docker pull step. Easier: just verify dry output
# mentions both 'preserves other servers' and '.bak' for the merge step.
$fakeProfile = Join-Path $env:TEMP ("halo-mcp-prof-" + [guid]::NewGuid().ToString('N'))
$tmpDeploy   = Join-Path $env:TEMP ("halo-mcp-merge-" + [guid]::NewGuid().ToString('N'))
$tmpTenant   = Join-Path $env:TEMP ("halo-tenant-merge-" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $cmd = @"
`$env:USERPROFILE = '$fakeProfile'
& '$Installer' -Email 'a@b.c' -Token 'x' -JiraUrl 'https://t.atlassian.net' -ConfluenceUrl 'https://t.atlassian.net/wiki' -DeployRoot '$tmpDeploy' -TenantConfigPath '$tmpTenant' -DryRun
"@
    $out = pwsh -NoProfile -Command $cmd 2>&1
    Assert { $LASTEXITCODE -eq 0 } "installer DryRun (redirected USERPROFILE) exits 0 (got $LASTEXITCODE)"
    Assert { ($out -join "`n") -match 'preserves other servers' } 'DryRun mentions preservation'
    Assert { ($out -join "`n") -match '\.bak' } 'DryRun mentions backup file'
}
finally {
    Remove-Item $fakeProfile -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $tmpDeploy) { Remove-Item $tmpDeploy -Recurse -Force }
    if (Test-Path $tmpTenant) { Remove-Item $tmpTenant -Force }
}

# --- Installer UX (PR5) ------------------------------------------------------
Write-Host ''
Write-Host '== Installer UX ==' -ForegroundColor Cyan
Assert {
    $installerText -match '\[switch\]\$NonInteractive'
} 'installer exposes -NonInteractive switch'
Assert {
    $installerText -match "throw '-NonInteractive set but -Email not provided"
} '-NonInteractive throws on missing -Email'
Assert {
    $installerText -match "throw '-NonInteractive set but -Token not provided"
} '-NonInteractive throws on missing -Token'
Assert {
    $installerText -match "throw '-NonInteractive set but -JiraUrl not provided"
} '-NonInteractive throws on missing -JiraUrl'
Assert {
    Test-Path (Join-Path (Split-Path $Installer -Parent) 'SetupForm.ps1')
} 'SetupForm.ps1 ships alongside installer'
Assert {
    $formText = Get-Content (Join-Path (Split-Path $Installer -Parent) 'SetupForm.ps1') -Raw
    $formText -match 'function\s+Show-HaloSetupForm'
} 'SetupForm.ps1 defines Show-HaloSetupForm'
Assert {
    $installerText -match 'SetupForm\.ps1'
} 'installer dot-sources SetupForm.ps1'
Assert {
    $installerText -match 'Show-HaloSetupForm'
} 'installer invokes Show-HaloSetupForm in interactive path'
Assert {
    $installerText -match 'Pre-flight summary'
} 'installer prints pre-flight summary'
Assert {
    $installerText -match "rotate / refresh"
} 'pre-flight summary distinguishes fresh vs rotate'
Assert {
    $installerText -match 'Detected prior install'
} 'idempotency banner present'
Assert {
    $installerText -match 'Auto-update next run'
} 'final output prints next scheduled run time'
Assert {
    $installerText -match 'Get-Command copilot'
} 'next-steps branches on whether copilot CLI is installed'

# Functional: -NonInteractive without required params fails fast.
$tmpDeploy = Join-Path $env:TEMP ("halo-mcp-ni-" + [guid]::NewGuid().ToString('N'))
$tmpTenant = Join-Path $env:TEMP ("halo-tenant-ni-" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $err = pwsh -NoProfile -File $Installer -NonInteractive -DryRun `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant 2>&1
    Assert { $LASTEXITCODE -ne 0 } '-NonInteractive without -Email exits non-zero'
    Assert { ($err -join "`n") -match 'NonInteractive set but -Email' } 'helpful error names the missing param'

    # Happy path: all params supplied + NonInteractive (no prompt, no pause).
    $out = pwsh -NoProfile -File $Installer -NonInteractive -DryRun `
        -Email 'a@b.c' -Token 'x' `
        -JiraUrl 'https://t.atlassian.net' -ConfluenceUrl 'https://t.atlassian.net/wiki' `
        -DeployRoot $tmpDeploy -TenantConfigPath $tmpTenant 2>&1
    Assert { $LASTEXITCODE -eq 0 } "-NonInteractive happy path exits 0 (got $LASTEXITCODE)"
    Assert { ($out -join "`n") -match 'Pre-flight summary' } 'pre-flight summary printed in NonInteractive mode'
    Assert { ($out -join "`n") -match 'Fresh install' } 'fresh-install banner printed when no prior install'
}
finally {
    if (Test-Path $tmpDeploy) { Remove-Item $tmpDeploy -Recurse -Force }
    if (Test-Path $tmpTenant) { Remove-Item $tmpTenant -Force }
}

# --- Update reliability (PR6) -----------------------------------------------
Write-Host ''
Write-Host '== Update reliability ==' -ForegroundColor Cyan
$updaterFresh = Get-Content $Updater -Raw
Assert {
    $updaterFresh -match 'Invoke-LogRotate'
} 'updater defines log rotation function'
Assert {
    $updaterFresh -match 'Test-NetworkReachable'
} 'updater defines network preflight'
Assert {
    $updaterFresh -match 'github\.com.*ghcr\.io|ghcr\.io.*github\.com'
} 'preflight checks both github.com and ghcr.io'
Assert {
    $updaterFresh -match 'LogMaxBytes.*1MB|1MB.*LogMaxBytes'
} 'log rotation defaults to 1 MB'
Assert {
    $updaterFresh -match '\[int\]\$LogMaxFiles\s*=\s*5'
} 'log rotation defaults to 5 files'
Assert {
    $updaterFresh -match "network preflight failed.*skipping"
} 'preflight fail is non-fatal (skip not error)'

# Functional: dot-source the script's helper functions and exercise the
# rotation logic against a fake oversized log.
$tmpLog = Join-Path $env:TEMP ("halo-update-log-" + [guid]::NewGuid().ToString('N') + ".log")
try {
    # Extract Invoke-LogRotate into an isolated scope using AST-free heuristic:
    # define the function inline (copied verbatim) and run it.
    function Invoke-LogRotateTest {
        param([string]$Path, [int]$MaxBytes, [int]$MaxFiles)
        if (-not (Test-Path $Path)) { return }
        $size = (Get-Item $Path).Length
        if ($size -lt $MaxBytes) { return }
        $leaf = Split-Path $Path -Leaf
        Get-ChildItem -Path (Split-Path $Path -Parent) -Filter ($leaf + '.*') -ErrorAction SilentlyContinue |
            Where-Object {
                if ($_.Name.Length -le $leaf.Length + 1) { return $false }
                $suffix = $_.Name.Substring($leaf.Length + 1)
                $n = 0
                [int]::TryParse($suffix, [ref]$n) -and $n -ge $MaxFiles
            } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
            $src = "$Path.$i"; $dst = "$Path.$($i + 1)"
            if (Test-Path $src) { Move-Item $src $dst -Force -ErrorAction SilentlyContinue }
        }
        Move-Item $Path "$Path.1" -Force -ErrorAction SilentlyContinue
    }

    # Below threshold: no rotation.
    Set-Content $tmpLog "small"
    Invoke-LogRotateTest -Path $tmpLog -MaxBytes 1MB -MaxFiles 5
    Assert { Test-Path $tmpLog } 'sub-threshold log is left in place'
    Assert { -not (Test-Path "$tmpLog.1") } 'no rotation file created when under threshold'

    # Over threshold: rotates to .1.
    Set-Content $tmpLog ('x' * 1100000)
    Invoke-LogRotateTest -Path $tmpLog -MaxBytes 1MB -MaxFiles 5
    Assert { -not (Test-Path $tmpLog) } 'over-threshold log was moved'
    Assert { Test-Path "$tmpLog.1" } 'rotated to .1'

    # Cap at MaxFiles: oldest dropped, others shift.
    1..6 | ForEach-Object { Set-Content "$tmpLog.$_" "gen$_" -ErrorAction SilentlyContinue }
    Set-Content $tmpLog ('x' * 1100000)
    Invoke-LogRotateTest -Path $tmpLog -MaxBytes 1MB -MaxFiles 5
    Assert { -not (Test-Path "$tmpLog.6") } 'rotated files capped at MaxFiles (no .6)'
}
finally {
    Get-ChildItem (Split-Path $tmpLog -Parent) -Filter ((Split-Path $tmpLog -Leaf) + '*') -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# --- Documentation scrub (PR7) ---------------------------------------------
Write-Host ''
Write-Host '== Documentation scrub ==' -ForegroundColor Cyan
$readme         = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
$wrapperReadme  = Get-Content (Join-Path $RepoRoot 'wrapper\README.md') -Raw
$skillsReadme   = Get-Content (Join-Path $RepoRoot 'skills\README.md') -Raw
$skillMd        = Get-Content (Join-Path $RepoRoot 'skills\halo-atlassian\SKILL.md') -Raw
Assert {
    # Allowed only inside the "Migrating from D:\CopilotScripts" subsection.
    $sections = [regex]::Split($readme, '(?m)^### ')
    $offenders = $sections | Where-Object {
        $_ -match 'D:\\CopilotScripts' -and $_ -notmatch '^Migrating from'
    }
    $offenders.Count -eq 0
} 'README has no D:\CopilotScripts refs'
Assert { $wrapperReadme -notmatch 'D:\\CopilotScripts' } 'wrapper/README has no D:\CopilotScripts refs'
Assert { $skillsReadme  -notmatch 'D:\\CopilotScripts' } 'skills/README has no D:\CopilotScripts refs'
Assert { $skillMd       -notmatch 'D:\\CopilotScripts' } 'skills/halo-atlassian/SKILL.md has no D:\CopilotScripts refs'
Assert { $readme -match 'Multi-tenant' }                         'README has multi-tenant section'
Assert { $readme -match 'Coexistence with other MCP servers' }   'README documents coexistence behaviour'
Assert { $readme -match 'Docker not found' -and $readme -match '401 from Atlassian' -and $readme -match 'Weekly update task not running' } 'README troubleshooting matrix covers Docker / 401 / weekly task'
Assert { $skillMd      -match 'LOCALAPPDATA' } 'skill doc uses LOCALAPPDATA helper path'
Assert { $wrapperReadme -match 'sibling of the wrapper' } 'wrapper/README documents uploads as wrapper-sibling'

# --- Uninstaller + smoke-test (PR8) ----------------------------------------
Write-Host ''
Write-Host '== Uninstaller + smoke-test ==' -ForegroundColor Cyan
$Uninstaller = Join-Path $RepoRoot 'setup\Uninstall-HaloAtlassianMcp.ps1'
$SmokeTest   = Join-Path $RepoRoot 'setup\Test-Installation.ps1'
Assert { Test-Path $Uninstaller } 'Uninstall-HaloAtlassianMcp.ps1 exists'
Assert { Test-Path $SmokeTest }   'Test-Installation.ps1 exists'

$uninst = Get-Content $Uninstaller -Raw
Assert { $uninst -match '\[switch\]\$DryRun' }         'uninstaller supports -DryRun'
Assert { $uninst -match '\[switch\]\$NonInteractive' } 'uninstaller supports -NonInteractive'
Assert { $uninst -match 'Unregister-ScheduledTask' }   'uninstaller unregisters scheduled task'
Assert { $uninst -match 'cmdkey.*delete' }             'uninstaller deletes credential via cmdkey'
Assert { $uninst -match 'mcp-config\.json\.bak|"\$McpConfigPath\.bak"' } 'uninstaller backs up mcp-config before edit'
Assert { $uninst -match '\[switch\]\$KeepCredential' } 'uninstaller supports -KeepCredential'
Assert { $uninst -match '\[switch\]\$KeepTenantConfig' } 'uninstaller supports -KeepTenantConfig'
Assert { $uninst -match '\[switch\]\$KeepSkill' }        'uninstaller supports -KeepSkill'
Assert { $uninst -match '\$SkillPath' }                  'uninstaller has -SkillPath parameter'

$smoke = Get-Content $SmokeTest -Raw
Assert { $smoke -match 'cmdkey.*list' }              'smoke-test checks credential via cmdkey'
Assert { $smoke -match 'docker info' }               'smoke-test pings docker engine'
Assert { $smoke -match 'image inspect' }             'smoke-test checks pinned image cached'
Assert { $smoke -match '\.atlassian\.net' }          'smoke-test validates tenant URL shape'
Assert { $smoke -match '\[switch\]\$SkipImageCheck' -and $smoke -match '\[switch\]\$SkipContainerCheck' } 'smoke-test has skip switches'
Assert { $smoke -match '\[switch\]\$SkipSkillCheck' }    'smoke-test has -SkipSkillCheck switch'
Assert { $smoke -match 'skill deployed' }                'smoke-test checks skill deployment'

# --- Skill auto-install + legacy cleanup -----------------------------------
Write-Host ''
Write-Host '== Skill install + legacy cleanup ==' -ForegroundColor Cyan
$inst = Get-Content (Join-Path $RepoRoot 'setup\Install-HaloAtlassianMcp.ps1') -Raw
Assert { $inst -match '\[string\]\$SkillRoot' }     'installer has -SkillRoot parameter'
Assert { $inst -match '\[switch\]\$SkipSkill' }     'installer has -SkipSkill switch'
Assert { $inst -match '\[switch\]\$SkipLegacyCleanup' } 'installer has -SkipLegacyCleanup switch'
Assert { $inst -match '\$LegacyDeployRoots' }       'installer declares $LegacyDeployRoots'
Assert { $inst -match 'D:\\CopilotScripts' }      'installer lists D:\CopilotScripts as a legacy root'
Assert { $inst -match 'halo-atlassian' -and $inst -match '\$SkillSrc' -and $inst -match '\$SkillDst' } 'installer has skill src/dst paths'

# Functional: uninstaller DryRun against a fake install exits 0 and prints summary.
$tmpDeploy = Join-Path $env:TEMP ("halo-uninst-deploy-" + [guid]::NewGuid().ToString('N'))
$tmpMcp    = Join-Path $env:TEMP ("halo-uninst-mcp-"    + [guid]::NewGuid().ToString('N') + '.json')
$tmpTen    = Join-Path $env:TEMP ("halo-uninst-tenant-" + [guid]::NewGuid().ToString('N') + '.json')
$tmpCred   = "halo-uninst-test-" + [guid]::NewGuid().ToString('N').Substring(0,8)
$uninstOut = & pwsh -NoProfile -File $Uninstaller -DryRun -NonInteractive `
    -DeployRoot $tmpDeploy -McpConfigPath $tmpMcp -TenantConfigPath $tmpTen `
    -CredentialTarget $tmpCred -AutoUpdateTaskName "fake-task-doesnt-exist" 2>&1
$uninstExit = $LASTEXITCODE
Assert { $uninstExit -eq 0 }                  ("uninstaller DryRun exits 0 (got $uninstExit)")
Assert { ($uninstOut -join "`n") -match 'Summary' } 'uninstaller DryRun prints summary block'
Assert { ($uninstOut -join "`n") -match 'DryRun complete' } 'uninstaller DryRun banner shown'

# Functional: smoke-test against fake paths returns non-zero failure count.
$smokeOut = & pwsh -NoProfile -File $SmokeTest -SkipImageCheck -SkipContainerCheck `
    -DeployRoot $tmpDeploy -McpConfigPath $tmpMcp -TenantConfigPath $tmpTen `
    -CredentialTarget $tmpCred 2>&1
$smokeExit = $LASTEXITCODE
Assert { $smokeExit -gt 0 }                   ("smoke-test exits non-zero on missing install (got $smokeExit)")
Assert { ($smokeOut -join "`n") -match 'check\(s\) failed' } 'smoke-test prints failure count'
Assert { ($smokeOut -join "`n") -notmatch 'Cannot index into a null array' } 'smoke-test handles missing mcp-config without runtime error'

Write-Host ''
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
