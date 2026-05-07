# Threat model — halo-mcp-atlassian

## Assets
- Atlassian Cloud API token (CopilotVault-managed)
- Issue / page contents (may contain confidential studio data)
- Build pipeline + container registry

## Trust boundaries
1. Copilot CLI host (developer workstation) <-> container (stdio)
2. Container <-> Atlassian Cloud (HTTPS)
3. CI pipeline <-> registry (OIDC + cosign)

## Mitigations vs. sooperset weaknesses
| Sooperset weakness | Mitigation in this repo |
|---|---|
| Single maintainer | Halo-owned, multi-owner, code review required |
| `:latest` tag drift | Consumers pin by digest; CI signs with cosign |
| No SBOM | `syft` SBOM generated and attested every build |
| No CVE gate | Trivy + Docker Scout fail on HIGH/CRITICAL; weekly rebuild |
| Token logged accidentally | structlog redaction in `logging.py`; bodies never logged |
| Container reads host files | distroless, non-root, `--read-only`, `--cap-drop=ALL`, no host mounts (uploads use `:ro` narrow path only) |
| Container phones home | Egress firewall: allow only `*.atlassian.net` and `api.atlassian.com` (ops doc) |
| No audit trail | structlog JSON to stderr -> Sentinel via host shipper |
| Pinned-version supply chain | `requirements.lock` with `--generate-hashes`; CI verifies hashes |
| Wide tool surface (~70) | v1 ships 16 tools matching actual usage |
| Token has full user scope | Phase 6 OAuth 3LO migration |
| SSRF via tool inputs | Base URL hard-bound in `Config`; tools accept only path/query, validated `.atlassian.net` host |

## Open Phase 0 decisions (defaults until security signs off)
1. Registry: GHCR for v1, internal ACR before GA
2. Auth v1: shared service-account API token from CopilotVault
3. Audit destination: Sentinel via existing host shipping
4. Scope at v1: full 16-tool surface (read+write)
5. Repo ownership: IT Operations + Studio Tools

## Out of scope
Server/Data Center, Bitbucket/Trello/Compass, web UI, AI features.
