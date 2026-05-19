# halo-mcp-atlassian

Self-hosted MCP server for Atlassian Cloud. Signed, scanned, distroless.

- Protocol: MCP (FastMCP, Python SDK)
- APIs: Jira REST v3, Confluence REST v2, JSM Assets v1
- Auth (v1): Basic (email + API token); OAuth 3LO planned for v6
- Image: distroless python3 (non-root, read-only rootfs)

## Quick start (dev)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e ".[dev]"
$env:ATLASSIAN_JIRA_URL = "https://your-tenant.atlassian.net"
$env:ATLASSIAN_CONFLUENCE_URL = "https://your-tenant.atlassian.net/wiki"
$env:ATLASSIAN_EMAIL = "you@example.com"
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

The installer prompts for your Atlassian email + API token + tenant URL, then:

1. Stores email + token in **Windows Credential Manager** (Generic credential
   `halo-atlassian:api-token`). Inspect with
   `cmdkey /list:halo-atlassian:api-token`.
2. Writes your tenant URLs (Jira + Confluence base) to
   `%USERPROFILE%\.halo-atlassian.json`. Non-secret, per-user, not
   committed.
3. Deploys `mcp-halo-atlassian.ps1` + `CredentialStore.ps1` to
   `D:\CopilotScripts\`.
4. Merges a `halo-atlassian` entry into `~/.copilot/mcp-config.json`
   (other MCP servers in that file are preserved).
5. `docker pull`s the pinned image digest.
6. Runs the container `--check` self-test.
7. Registers a weekly Windows Scheduled Task
   (`HaloMcpAtlassian-AutoUpdate`, Mondays 03:30 local) that runs
   `setup/Update-HaloAtlassianMcp.ps1` so the repo and image stay fresh
   without any manual steps. Skip with `-SkipAutoUpdate`.

Re-run the installer any time to **rotate your token** or change tenant.

Non-interactive (CI / scripted):

```powershell
.\setup\Install-HaloAtlassianMcp.ps1 `
  -Email you@example.com `
  -Token "$env:ATLASSIAN_TOKEN" `
  -JiraUrl "https://your-tenant.atlassian.net"
```

`-DryRun` prints every step without writing anything.

### Optional — enable Assets write tools

By default only **read** tools for Atlassian Assets (CMDB) register
(`assets_aql_search`, `assets_get_object`, `assets_list_object_types`,
etc.). The three create/update/delete tools are gated behind two env
vars the wrapper forwards into the container.

Set both as **User** environment variables so Copilot CLI (and the
wrapper it launches) inherit them:

```powershell
# 1. Master switch — enable Assets create/update/delete tools
[Environment]::SetEnvironmentVariable('HALO_MCP_ASSETS_WRITE', '1', 'User')

# 2. Allow-list of objectType IDs the write tools may touch.
#    Discover IDs first: ask Copilot to run assets_list_object_types(<schemaId>)
[Environment]::SetEnvironmentVariable(
    'HALO_MCP_ASSETS_WRITE_OBJECT_TYPES',
    '<comma-separated numeric IDs>',
    'User')

# 3. Close and reopen your terminal so the new env vars are loaded, then:
copilot
```

Verify in a fresh session:

```powershell
# In Copilot CLI:
/tools   # confirm halo-atlassian-assets_create_object etc. now appear
```

Disable by clearing the master switch:

```powershell
[Environment]::SetEnvironmentVariable('HALO_MCP_ASSETS_WRITE', $null, 'User')
```

Notes:
- Write tools require the API token's user to have **Assets write
  permission** on the target schema/objectType. Read access is not enough.
- The allow-list is a safety net: if `HALO_MCP_ASSETS_WRITE_OBJECT_TYPES`
  is empty or missing, write tools refuse to run even when the master
  switch is on.
- Both vars are User-scope (not Machine), so this is per-Windows-user and
  doesn't need admin.

### Multi-tenant / non-Halo deployment

The installer is tenant-agnostic. If you're not on the Halo Studios
tenant, pass your own URLs (or just respond to the prompts):

```powershell
.\setup\Install-HaloAtlassianMcp.ps1 `
  -JiraUrl "https://your-tenant.atlassian.net" `
  -ConfluenceUrl "https://your-tenant.atlassian.net"
```

URLs are validated (must be `https://`, must end in `.atlassian.net`)
and written to `%USERPROFILE%\.halo-atlassian.json`. The wrapper
resolves the tenant in this order: explicit env var
(`ATLASSIAN_JIRA_URL` / `ATLASSIAN_CONFLUENCE_URL`) →
`%USERPROFILE%\.halo-atlassian.json`. There is **no hardcoded tenant**
fallback in the wrapper or installer.

`-NonInteractive` requires `-Email`, `-Token`, `-JiraUrl`, and
`-ConfluenceUrl` up front; it fails fast naming the missing param if
any is omitted.

### Coexistence with other MCP servers

The installer **preserves any existing `mcpServers` entries** in
`~/.copilot/mcp-config.json`. Before any write it backs up the file to
`mcp-config.json.bak`. If a `halo-atlassian` entry already exists, it is
overwritten in place (a warning is printed so the change is visible).
After merge, the installer prints a one-line summary of which sibling
servers were preserved.

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
| `Cannot find image` | Pinned digest is gone from upstream GHCR. Either wait for the next auto-bump PR + Monday update, or fork the repo and host your own image (see [Fork and host your own image](#fork-and-host-your-own-image)). |
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

After a successful promotion, the `bump-wrapper-digest` step in `ci.yml`
opens an auto-merging PR that updates `$DefaultImage` (and demotes the old
digest to `$PreviousImage`) in the wrapper. By the time the Monday update
task on each user's machine runs, the wrapper already points at the new
green image.

## Fork and host your own image

If you don't want to depend on `ghcr.io/v-nguyenmich/halo-mcp-atlassian`
(air-gapped network, separate org, compliance, etc.), self-host the image
under your own GHCR namespace. The wrapper supports it without any code
changes.

1. **Fork** this repo on GitHub.
2. Push a commit (or use **Actions → run workflow** on `ci.yml`). CI will
   build, scan, sign, and push to `ghcr.io/<your-user-or-org>/halo-mcp-atlassian`
   under your account. Tag `:stable` is promoted only on a green Trivy run.
3. Make the package public (Profile → Packages → `halo-mcp-atlassian` →
   Package settings → Change visibility) **or** distribute a `read:packages`
   PAT for each user.
4. On each user workstation, point the wrapper at your image. Two options:
   ```powershell
   # Option A: per-user env override (no repo edit needed)
   [Environment]::SetEnvironmentVariable(
     'HALO_MCP_IMAGE',
     'ghcr.io/<your-user-or-org>/halo-mcp-atlassian:stable',
     'User')

   # Option B: edit wrapper/mcp-halo-atlassian.ps1 in your fork
   #   $DefaultImage  = 'ghcr.io/<your-user-or-org>/halo-mcp-atlassian@sha256:...'
   #   $PreviousImage = 'ghcr.io/<your-user-or-org>/halo-mcp-atlassian@sha256:<previous>'
   ```
5. Users clone **your fork** (not upstream) and run the installer normally.
   The weekly auto-update task pulls from your fork + your registry.
6. Optional: enable Renovate + the auto-bump-wrapper PR on your fork by
   keeping `renovate.json` and `.github/workflows/automerge.yml`. To allow
   the `bump-wrapper-digest` step to open PRs that re-trigger CI, add a
   fine-grained PAT with `contents: write` + `pull-requests: write` as the
   `WRAPPER_BUMP_PAT` secret. Without it, the bump PR opens but CI won't
   re-run on it (a `GITHUB_TOKEN`-authored PR doesn't trigger workflows),
   so you'll need to push an empty commit or merge manually.

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

