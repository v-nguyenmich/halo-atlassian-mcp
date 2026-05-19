# Copilot CLI wrapper

`mcp-halo-atlassian.ps1` is the launcher invoked by GitHub Copilot CLI to start
the `halo-mcp-atlassian` MCP server inside Docker.

## What it does

- Dot-sources `CredentialStore.ps1` (sibling file) and reads the Atlassian
  email + API token from **Windows Credential Manager** generic credential
  `halo-atlassian:api-token` via Win32 P/Invoke. **No PSGallery modules.**
- Pulls a pinned image digest (`$DefaultImage`) from GHCR.
- Runs a self-check (`--check`) before serving stdio MCP traffic.
- If the pinned image fails the check, falls back to a previous-known-good
  digest (`$PreviousImage`).
- Mounts an `uploads/` directory (sibling of the wrapper) read-only into
  the container at `/uploads` for attachment uploads. Auto-created on
  first run.

## Deployment

Run `setup\Install-HaloAtlassianMcp.ps1` from the repo root. The installer
prompts for email + token, writes the credential, copies this wrapper and
`CredentialStore.ps1` into the deploy root
(`%LOCALAPPDATA%\Programs\halo-mcp-atlassian\` by default; override with
`-DeployRoot`), merges a `halo-atlassian` entry into
`~/.copilot/mcp-config.json` (preserving siblings, backing up to
`mcp-config.json.bak`), pulls the pinned image, and runs `--check`. Re-run
any time to rotate the token.

To inspect / manually manage the credential:

```powershell
cmdkey /list:halo-atlassian:api-token        # show entry
cmdkey /delete:halo-atlassian:api-token      # remove
```

## Overrides

| Env var                              | Effect                                                  |
| ------------------------------------ | ------------------------------------------------------- |
| `HALO_MCP_IMAGE`                     | Use a different image digest/tag for canary testing.    |
| `HALO_MCP_PREV_IMAGE`                | Override the fallback digest.                           |
| `HALO_MCP_NO_PULL=1`                 | Skip `docker pull` (offline/cached).                    |
| `HALO_MCP_ASSETS_WRITE=1`            | Enable Assets create/update/delete tools (default OFF). |
| `HALO_MCP_ASSETS_WRITE_OBJECT_TYPES` | Comma-separated numeric objectType IDs allowed.         |
| `ATLASSIAN_JIRA_URL`                 | Override Jira tenant (from `tenant.json` / `~/.halo-atlassian.json`). |
| `ATLASSIAN_CONFLUENCE_URL`           | Override Confluence tenant (from `tenant.json` / `~/.halo-atlassian.json`). |

