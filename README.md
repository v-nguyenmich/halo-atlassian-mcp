# halo-mcp-atlassian

Halo Studios local MCP server for Atlassian Cloud. Replaces
`sooperset/mcp-atlassian` with an in-house, signed, audited build.

- Protocol: MCP (FastMCP, Python SDK)
- APIs: Jira REST v3, Confluence REST v2
- Auth (v1): Basic (email + API token); OAuth 3LO planned for v6
- Image: distroless python3 (non-root, read-only rootfs)

## Quick start (dev)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e ".[dev]"
$env:ATLASSIAN_JIRA_URL = "https://343industries.atlassian.net"
$env:ATLASSIAN_CONFLUENCE_URL = "https://343industries.atlassian.net"
$env:ATLASSIAN_EMAIL = "you@halostudios.com"
$env:ATLASSIAN_API_TOKEN = "..."
python -m halo_mcp_atlassian
```

## Test

```powershell
pytest -q
ruff check src tests
```

## Build

```powershell
docker build -t halo-mcp-atlassian:dev .
```

## Coexistence with sooperset

Both servers can run simultaneously. This one registers as
`halo-atlassian`; sooperset typically registers as `atlassian`.
See `docs/operations.md`.

## User setup (GitHub Copilot CLI on Windows)

End-to-end recipe for wiring this MCP server into the GitHub Copilot CLI on a
new Windows workstation. Result: typing `copilot` opens a session that has the
`halo-atlassian` tool surface (Jira + Confluence + Assets) available.

### Prerequisites

- Windows 10/11, **PowerShell 7+** (`pwsh`).
- **Docker Desktop** installed and running (the wrapper runs the MCP server in
  a container).
- **Node.js LTS** (for installing the Copilot CLI).
- An **Atlassian API token** — create at <https://id.atlassian.com/manage-profile/security/api-tokens>.

### 1. Install GitHub Copilot CLI

```powershell
npm install -g @github/copilot
```

### 2. Store the Atlassian API token in a SecretManagement vault

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser -Force
Register-SecretVault -Name CopilotVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
# Optional: remove interactive prompt for the vault
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false

Set-Secret -Name AtlassianApiToken -Secret (Read-Host -AsSecureString "Atlassian API token")
```

The wrapper looks for **vault `CopilotVault`**, **secret `AtlassianApiToken`** —
do not rename either.

### 3. Clone this repo and place the wrapper script

```powershell
mkdir D:\CopilotScripts -Force | Out-Null
cd D:\CopilotScripts
git clone https://github.com/v-nguyenmich/halo-atlassian-mcp.git halo-mcp-atlassian

# Copy the active wrapper into the location Copilot CLI will launch
Copy-Item D:\CopilotScripts\halo-mcp-atlassian\wrapper\mcp-halo-atlassian.ps1 D:\CopilotScripts\mcp-halo-atlassian.ps1 -Force
```

Edit `D:\CopilotScripts\mcp-halo-atlassian.ps1` line 30 (`$env:ATLASSIAN_EMAIL`)
to your own `@halostudios.com` email. Everything else can stay default.

### 4. Pre-pull the pinned MCP image

```powershell
# Match the digest currently pinned in the wrapper's $DefaultImage
docker pull ghcr.io/v-nguyenmich/halo-mcp-atlassian@sha256:82c1f51bb4de0c91440bf213663fab7657d90ae05132a54437b7625e801ebbd3
```

### 5. Register the wrapper with Copilot CLI

Create or edit `~/.copilot/mcp-config.json`:

```powershell
$cfgPath = "$env:USERPROFILE\.copilot\mcp-config.json"
New-Item (Split-Path $cfgPath) -ItemType Directory -Force | Out-Null
@'
{
  "mcpServers": {
    "halo-atlassian": {
      "type": "local",
      "command": "pwsh.exe",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "D:\\CopilotScripts\\mcp-halo-atlassian.ps1"
      ],
      "tools": ["*"],
      "env": {}
    }
  }
}
'@ | Set-Content $cfgPath -Encoding UTF8
```

> Copilot CLI uses **`mcp-config.json`** for MCP servers. Older docs reference
> `config.json` or `mcp.json` — those are NOT used by the CLI.

### 6. (Optional) Add a `copilot-instructions.md` for tenant-specific context

`~/.copilot/copilot-instructions.md` is loaded into every session. Useful
entries:

```markdown
- Atlassian site: https://343industries.atlassian.net
- Atlassian email: <your @halostudios.com address>
- API token storage: SecretManagement vault "CopilotVault", secret "AtlassianApiToken"
- Jira accountId: <your accountId>
- Confluence personal space:
  - Space key: <KEY>
  - Space ID:  <numeric>
  - Homepage ID (default parent for new pages): <numeric>
```

The Confluence personal-space numeric IDs save Copilot from a slow lookup loop
when you ask it to publish a page; without them it has to ask you for the URL.

### 7. Verify

```powershell
copilot
# In session:
> /tools                 # confirm halo-atlassian tools registered
> ask: "list my open Jira tickets in DCCSUP"
```

If `/tools` doesn't show halo-atlassian tools:

```powershell
# Run the wrapper standalone to see startup errors
pwsh -NoProfile -File D:\CopilotScripts\mcp-halo-atlassian.ps1
# Common failures:
#  - "failed to read AtlassianApiToken from CopilotVault" -> step 2 not done
#  - "Cannot find image" -> step 4 not done, or HALO_MCP_NO_PULL set with empty cache
#  - "health check FAILED" -> token invalid or Atlassian URL unreachable
```

### Updating the pinned image

When a new digest is promoted, edit the `$DefaultImage` line in
`wrapper/mcp-halo-atlassian.ps1`, copy it back to
`D:\CopilotScripts\mcp-halo-atlassian.ps1`, and `docker pull` the new digest.
The previous `$DefaultImage` value should move into `$PreviousImage` to
preserve the auto-fallback path.

## Tools (v1)

See `docs/tool-reference.md`. 16 tools total: 9 Jira + 7 Confluence.

## Copilot CLI skill

See [`skills/`](./skills/) for an optional Copilot CLI skill that pairs with this server and packages common Jira / Assets / Confluence workflows.

## Security posture

See `docs/threat-model.md`.

---

_This project was created with the help of AI and reviewed by Michael Nguyen._
