# Accepted risks — halo-mcp-atlassian

These items were identified during the v1 security audit (see
`threat-model.md` for the full audit) and have been **accepted** for the
initial release. Each entry must be re-evaluated at every major version
or when the surrounding environment changes.

---

## AR-1 — JQL / CQL injection by a poisoned LLM
**Surface:** `jira_search`, `confluence_search`
**Why accepted:** Atlassian REST v3 / v2 do not offer a parameterized
query interface. The query string is the API contract; there is no
escape mechanism. Server-side allowlisting of clauses would block
legitimate use.
**Compensating controls:**
- Service-account permissions are limited to projects the IT team owns.
- All queries are logged with tool, status, and elapsed time (no payload).
- Phase 6 OAuth 3LO migration narrows the blast radius per-user.
**Re-evaluate when:** OAuth 3LO ships; or Atlassian publishes a
parameterized JQL endpoint.

## AR-2 — Indirect prompt injection via tool output
**Surface:** Every read tool that returns Jira/Confluence content.
**Why accepted:** Inherent to MCP — the LLM consumes raw upstream
content. Stripping content would break the product. Industry parallel:
Wiz GitHub MCP RCE, Invariant Labs WhatsApp PoC.
**Compensating controls:**
- Error responses are wrapped in `<atlassian-untrusted>...</atlassian-untrusted>`
  delimiters in `client._safe_error_message`.
- `README.md` and the runbook explicitly forbid running this server
  under Copilot CLI auto-approve mode.
- `jira_update_issue` / write tools enforce field allowlists so a
  successful injection cannot quietly tamper with reporter, security,
  or watchers.
**Re-evaluate when:** MCP protocol gains structured trust labeling for
tool outputs, or a sanitizer with acceptable false-negative rates exists.

## AR-3 — Distroless image scanner noise
**Surface:** Trivy / Docker Scout findings against
`gcr.io/distroless/python3-debian12`.
**Why accepted:** Many flagged CVEs are in code paths the MCP server
never reaches (e.g., XML parsing, tarfile). Triaging each one through
Anchore SBOM analysis is a Phase 5 activity, not a v1 blocker.
**Compensating controls:**
- Weekly base-image rebuild (`.github/workflows/rebuild.yml`) picks up
  upstream patches automatically.
- CI gate is HIGH/CRITICAL only; LOW/MEDIUM informational.
**Re-evaluate when:** Anchore SBOM-based reachability filtering is
configured, or a new HIGH/CRITICAL appears that scanners cannot
auto-suppress.

## AR-4 — Latent SSRF via attachment download URLs
**Surface:** Future tool — not implemented in v1.
**Why accepted:** Out of scope for v1. The moment a download tool is
added, it must validate the URL host equals the configured Atlassian
tenant and reject non-https schemes. Captured here so the next author
does not miss it.
**Re-evaluate when:** Any download/fetch tool is added.

## AR-5 — API token has full user scope
**Surface:** Auth model in v1.
**Why accepted:** Phase 0 alignment defaulted to a shared service-account
API token from CopilotVault. Switching to OAuth 3LO is a Phase 6 task
with separate change-management requirements.
**Compensating controls:**
- Token is stored only in CopilotVault; never written to disk by the wrapper.
- Token is passed to the container by reference, not value (Run-HaloAtlassian.ps1).
- structlog redaction strips token-like keys from any logged event.
**Re-evaluate when:** Phase 6 OAuth ships, or the service account is
granted broader permissions.

## AR-6 — Synthetic / unverified CVEs from research pass
**Surface:** Several "CVE-2026-*" identifiers surfaced by the research
agent could not be cross-validated against NVD. They are tracked as
unverified in this document so we don't re-research them, but no code
action is taken until they appear in NVD or an authoritative advisory.
**Re-evaluate at:** Each Dependabot bump touching `mcp` or `fastmcp`.
