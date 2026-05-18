# Threat model — halo-mcp-atlassian

## Assets
- Atlassian Cloud API token (Windows Credential Manager, generic credential `halo-atlassian:api-token`)
- Issue / page contents (may contain confidential studio data)
- Build pipeline + container registry

## Trust boundaries
1. Copilot CLI host (developer workstation) <-> container (stdio)
2. Container <-> Atlassian Cloud (HTTPS)
3. CI pipeline <-> registry (OIDC + cosign)

## Posture
| Concern | Control in this repo |
|---|---|
| Maintainer bus factor | Halo-owned, multi-owner, code review required |
| Tag drift / supply chain pinning | Consumers pin by digest; CI signs with cosign |
| SBOM | `syft` SBOM generated and attested every build |
| CVE gate | Trivy + Docker Scout fail on HIGH/CRITICAL; weekly rebuild |
| Token leakage in logs | structlog redaction in `logging.py`; bodies never logged |
| Container access to host files | distroless, non-root, `--read-only`, `--cap-drop=ALL`, `--tmpfs /tmp`, **attachment uploads constrained to `upload_root` after `realpath` check** (`tools/confluence.py::_resolve_upload_path`) |
| Container egress | Egress firewall: allow only `*.atlassian.net` and `api.atlassian.com` (ops doc) |
| Audit trail | structlog JSON to stderr -> Sentinel via host shipper |
| Lockfile integrity | `requirements.lock` with `--generate-hashes`; CI verifies hashes |
| Tool surface size | v1 ships ~22 tools matching actual usage; Assets write surface is opt-in via `HALO_MCP_ASSETS_WRITE` + objectType allowlist |
| Token scope | Phase 6 OAuth 3LO migration |
| SSRF via tool inputs | Base URL hard-bound in `Config`; tools accept only path/query, validated `.atlassian.net` host |
| Credential storage on host | Windows Credential Manager (DPAPI-encrypted per user); no PSGallery dependency on the wrapper |

## Open Phase 0 decisions (defaults until security signs off)
1. Registry: GHCR for v1, internal ACR before GA
2. Auth v1: per-user API token in Windows Credential Manager
3. Audit destination: Sentinel via existing host shipping
4. Scope at v1: full read surface (read+write for Jira/Confluence; Assets read by default, write opt-in)
5. Repo ownership: IT Operations + Studio Tools

## Phase 3+ defenses added
- `confluence_upload_attachment` — `upload_root` jail, symlink-safe via `realpath`
- `confluence_create_page` / `update_page` — storage-format allowlist (rejects script/iframe/object/embed/inline event handlers/javascript: URLs/unsafe macros)
- `jira_update_issue` / `jira_create_issue` — field allowlist (`ALLOWED_UPDATE_FIELDS`)
- `jira_create_issue` — `X-Atlassian-Idempotency` header on creation
- `client.py` — total-request budget (120s) + capped `Retry-After` (30s)
- `client._safe_error_message` — wraps Atlassian content in `<atlassian-untrusted>` delimiters
- `logging.py` — recursive secret redaction (nested dicts/lists)
- `wrapper/mcp-halo-atlassian.ps1` — token passed by env reference, not command-line value; `--tmpfs /tmp`; credential pulled from Windows Credential Manager via P/Invoke (no PSGallery deps)
- `pyproject.toml` / `requirements.lock` — `python-multipart>=0.0.20` floor pin (CVE-2024-24762, CVE-2024-53981)
- `.github/workflows/ci.yml` — actions pinned to commit SHAs; lockfile hash gate
- `.github/dependabot.yml` — weekly bumps for actions, pip, docker
- Assets write tools — opt-in via env, per-objectType allowlist, delete requires confirm_object_key match

## Accepted risks
See [accepted-risks.md](accepted-risks.md). Summary:
- AR-1 JQL/CQL injection (Atlassian API limitation)
- AR-2 indirect prompt injection via tool output (MCP-inherent)
- AR-3 distroless scanner phantom CVEs
- AR-4 latent SSRF (no download tool yet)
- AR-5 API token full-scope (until OAuth 3LO in Phase 6)
- AR-6 unverified CVE-2026-* identifiers from research pass
- AR-7 AQL passthrough (Atlassian enforces authz via API token)

## Out of scope
Server/Data Center, Bitbucket/Trello/Compass, web UI, AI features.
