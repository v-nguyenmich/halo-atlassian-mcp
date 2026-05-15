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

## Tools (v1)

See `docs/tool-reference.md`. 16 tools total: 9 Jira + 7 Confluence.

## Copilot CLI skill

See [`skills/`](./skills/) for an optional Copilot CLI skill that pairs with this server and packages common Jira / Assets / Confluence workflows.

## Security posture

See `docs/threat-model.md`.

---

_This project was created with the help of AI and reviewed by Michael Nguyen._
