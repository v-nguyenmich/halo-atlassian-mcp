# Operations runbook

## Required environment
| Var | Notes |
|---|---|
| ATLASSIAN_JIRA_URL | `https://343industries.atlassian.net` |
| ATLASSIAN_CONFLUENCE_URL | same as Jira on Cloud |
| ATLASSIAN_EMAIL | service account UPN |
| ATLASSIAN_API_TOKEN | from CopilotVault |
| HALO_MCP_LOG_LEVEL | INFO (default) |
| HALO_MCP_TIMEOUT_S | 30 |
| HALO_MCP_MAX_UPLOAD_BYTES | 52428800 |

## Run hardened (recommended flags)
```
docker run --rm -i \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=10m \
  --user 65532:65532 \
  --network=atlassian-egress \
  -v /srv/halo-mcp/uploads:/uploads:ro \
  -e ATLASSIAN_JIRA_URL -e ATLASSIAN_CONFLUENCE_URL \
  -e ATLASSIAN_EMAIL -e ATLASSIAN_API_TOKEN \
  -e HALO_MCP_UPLOAD_ROOT=/uploads \
  ghcr.io/halostudios/halo-mcp-atlassian@sha256:<digest>
```
Pass the API token by **reference** (`-e ATLASSIAN_API_TOKEN`, no value)
so the token never appears in the docker process command line.

## Egress allowlist
Only `*.atlassian.net` and `api.atlassian.com` (Atlassian Marketplace + media).
Block everything else at the host firewall.

## Verifying image signature
```
cosign verify ghcr.io/halostudios/halo-mcp-atlassian@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/halostudios/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Coexistence with sooperset
This server registers under MCP name `halo-atlassian`. Sooperset's entry
(usually `atlassian`) is left untouched. Add this entry to
`~/.copilot/mcp-config.json`:
```json
{
  "mcpServers": {
    "halo-atlassian": {
      "command": "powershell",
      "args": [
        "-NoProfile", "-File",
        "D:\\CopilotScripts\\halo-mcp-atlassian\\Run-HaloAtlassian.ps1"
      ]
    }
  }
}
```
The wrapper pulls the API token from CopilotVault and execs the pinned
container digest.

## Audit
structlog emits JSON to stderr. Each request logs:
`product`, `method`, `path`, `status`, `attempt`, `elapsed_ms`.
No request or response bodies are logged.
