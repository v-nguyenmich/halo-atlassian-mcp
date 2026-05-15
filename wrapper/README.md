# Copilot CLI wrapper

`mcp-halo-atlassian.ps1` is the launcher invoked by GitHub Copilot CLI to start
the `halo-mcp-atlassian` MCP server inside Docker.

## What it does

- Reads the Atlassian API token from a `Microsoft.PowerShell.SecretManagement`
  vault named `CopilotVault` (secret name `AtlassianApiToken`).
- Pulls a pinned image digest (`$DefaultImage`) from GHCR.
- Runs a self-check (`--check`) before serving stdio MCP traffic.
- If the pinned image fails the check, falls back to a previous-known-good
  digest (`$PreviousImage`).
- Mounts `D:\CopilotScripts\halo-mcp-atlassian\uploads` read-only into the
  container at `/uploads` for attachment uploads.

Override at runtime:

| Env var                              | Effect                                                  |
| ------------------------------------ | ------------------------------------------------------- |
| `HALO_MCP_IMAGE`                     | Use a different image digest/tag for canary testing.    |
| `HALO_MCP_PREV_IMAGE`                | Override the fallback digest.                           |
| `HALO_MCP_NO_PULL=1`                 | Skip `docker pull` (offline/cached).                    |
| `HALO_MCP_ASSETS_WRITE=1`            | Enable Assets create/update/delete tools (default OFF). |
| `HALO_MCP_ASSETS_WRITE_OBJECT_TYPES` | Comma-separated numeric objectType IDs allowed.         |

## Relationship to `Run-HaloAtlassian.ps1`

The repo also contains `Run-HaloAtlassian.ps1` at the repo root. That script is
an older reference wrapper that expects a `copilotvault` CLI binary and accepts
parameters via the command line. **The active wrapper used by Copilot CLI is
this one (`wrapper/mcp-halo-atlassian.ps1`)** — it uses
`Microsoft.PowerShell.SecretManagement` and is launched non-interactively by
the MCP host.

If you're setting up a new machine, follow `wrapper/README.md` (this file) and
the parent repo `README.md` "User setup" section — not the older script.
