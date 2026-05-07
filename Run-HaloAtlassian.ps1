#requires -Version 7.0
<#
.SYNOPSIS
  Stdio wrapper for halo-mcp-atlassian. Invoked by Copilot CLI via mcp-config.json.

.DESCRIPTION
  - Pulls API token from CopilotVault.
  - Execs the pinned container digest with hardened flags.
  - stdin/stdout pass through to the container; stderr is the audit stream.
#>

[CmdletBinding()]
param(
    [string]$ImageDigest = $env:HALO_MCP_IMAGE_DIGEST,
    [string]$JiraUrl = "https://343industries.atlassian.net",
    [string]$ConfluenceUrl = "https://343industries.atlassian.net",
    [string]$Email = $env:HALO_MCP_EMAIL
)

$ErrorActionPreference = "Stop"

if (-not $ImageDigest) {
    throw "HALO_MCP_IMAGE_DIGEST not set. Pin a verified digest from cosign output."
}
if (-not $Email) {
    throw "HALO_MCP_EMAIL not set."
}

try {
    $token = (& copilotvault get atlassian/api-token) 2>$null
    if (-not $token) { throw "empty" }
} catch {
    throw "Failed to read atlassian/api-token from CopilotVault: $_"
}

$dockerArgs = @(
    "run", "--rm", "-i",
    "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
    "--user", "65532:65532",
    "-e", "ATLASSIAN_JIRA_URL=$JiraUrl",
    "-e", "ATLASSIAN_CONFLUENCE_URL=$ConfluenceUrl",
    "-e", "ATLASSIAN_EMAIL=$Email",
    "-e", "ATLASSIAN_API_TOKEN=$token",
    $ImageDigest
)

& docker @dockerArgs
exit $LASTEXITCODE
