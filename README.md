# halo-mcp-atlassian

Halo Studios local MCP server for Atlassian Cloud. In-house, signed, audited build.

- Protocol: MCP (FastMCP, Python SDK)
- APIs: Jira REST v3, Confluence REST v2, JSM Assets v1
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
pwsh -NoProfile -File tests\test_wrapper.ps1   # wrapper / CredMan helper smoke
```

## Build

```powershell
docker build -t halo-mcp-atlassian:dev .
```

## User setup (GitHub Copilot CLI on Windows)

Three commands to a working `halo-atlassian` MCP server in Copilot CLI on a
fresh Windows workstation.

### Prerequisites

- Windows 10/11, **PowerShell 7+** (`pwsh`).
- **Docker Desktop** installed and running.
- **Node.js LTS** (only required for the Copilot CLI install at the end).
- An **Atlassian API token** — create at <https://id.atlassian.com/manage-profile/security/api-tokens>.

### Install

```powershell
git clone https://github.com/v-nguyenmich/halo-atlassian-mcp.git D:\CopilotScripts\halo-mcp-atlassian
cd D:\CopilotScripts\halo-mcp-atlassian
pwsh -NoProfile -File .\setup\Install-HaloAtlassianMcp.ps1
```

The installer prompts for your Atlassian email + API token, then:

1. Stores them in **Windows Credential Manager** (Generic credential
   `halo-atlassian:api-token`). Inspect with
   `cmdkey /list:halo-atlassian:api-token`.
2. Deploys `mcp-halo-atlassian.ps1` + `CredentialStore.ps1` to
   `D:\CopilotScripts\`.
3. Merges a `halo-atlassian` entry into `~/.copilot/mcp-config.json`
   (other MCP servers in that file are preserved).
4. `docker pull`s the pinned image digest.
5. Runs the container `--check` self-test.
6. Registers a weekly Windows Scheduled Task
   (`HaloMcpAtlassian-AutoUpdate`, Mondays 03:30 local) that runs
   `setup/Update-HaloAtlassianMcp.ps1` so the repo and image stay fresh
   without any manual steps. Skip with `-SkipAutoUpdate`.

Re-run the installer any time to **rotate your token** — no other steps.

Non-interactive (CI / scripted):

```powershell
.\setup\Install-HaloAtlassianMcp.ps1 -Email you@halostudios.com -Token "$env:ATLASSIAN_TOKEN"
```

`-DryRun` prints every step without writing anything.

### Finish

```powershell
npm install -g @github/copilot
copilot
# In session:
/tools                                    # verify halo-atlassian-* tools
```

### Troubleshooting

| Symptom | Fix |
|---|---|
| `no credential found at target 'halo-atlassian:api-token'` | Re-run `Install-HaloAtlassianMcp.ps1`. |
| `--check failed` | Token expired or revoked; rotate at id.atlassian.com and re-run installer. |
| `Cannot find image` | Pinned digest is gone from GHCR; pull `latest` of `ghcr.io/v-nguyenmich/halo-mcp-atlassian` or wait for new digest pin. |
| Copilot doesn't see new tools | Restart Copilot CLI session; tool list is cached at session start. |

### (Optional) Per-user instructions file

`~/.copilot/copilot-instructions.md` is loaded into every session. Helpful for
caching your Atlassian accountId, Confluence personal space IDs, etc., so
Copilot doesn't have to look them up each session.

### Updating the pinned image

You **don't have to do anything** — the installer registers a weekly
Scheduled Task (`HaloMcpAtlassian-AutoUpdate`) that runs
`setup/Update-HaloAtlassianMcp.ps1`:

1. `git pull --ff-only` on the cloned repo
2. Parses the new `$DefaultImage` digest from the freshly pulled wrapper
3. `docker pull <digest>`
4. Redeploys wrapper + helper to `D:\CopilotScripts\`

Logs land in `%LOCALAPPDATA%\HaloMcp\update.log`. Run it on demand with:

```powershell
pwsh -NoProfile -File .\setup\Update-HaloAtlassianMcp.ps1
```

Remove the auto-update task with:

```powershell
Unregister-ScheduledTask -TaskName HaloMcpAtlassian-AutoUpdate -Confirm:$false
```

#### How the digest itself gets bumped
On the repo side, **Renovate** (`renovate.json`) watches the distroless base
image and the GitHub Actions used by CI. When a new digest is available it
opens a PR; `.github/workflows/automerge.yml` auto-approves and squash-merges
once CI is green (Trivy HIGH/CRITICAL gate + signed image + SBOM attestation).
The weekly `rebuild.yml` job builds with `pull: true` / `no-cache: true` so
upstream base-image security fixes get picked up even without a Renovate PR.
The `:stable` tag is only re-pointed after Trivy passes, so consumers
following the digest pinned in `wrapper/mcp-halo-atlassian.ps1` never get a
red image.

## Tools

See `docs/tool-reference.md`. Currently 22 tools (9 Jira + 7 Confluence +
6 Assets read; optional 3 Assets write tools gated behind
`HALO_MCP_ASSETS_WRITE=1`).

## Copilot CLI skill

See [`skills/`](./skills/) for an optional Copilot CLI skill that pairs with
this server and packages common Jira / Assets / Confluence workflows.

## Security posture

See `docs/threat-model.md`.

---

_This project was created with the help of AI and reviewed by Michael Nguyen._

