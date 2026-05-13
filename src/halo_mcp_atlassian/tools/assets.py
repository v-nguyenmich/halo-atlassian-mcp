"""Jira Service Management Assets (formerly Insight) tools.

Assets lives on a different host (api.atlassian.com) and uses AQL, not JQL.
The workspace id is a tenant-scoped UUID; we either read it from
ATLASSIAN_ASSETS_WORKSPACE_ID env var or discover it once at startup via
the JSM REST endpoint on the Jira host.

Security posture mirrors jira.py:
- Tool inputs are AQL strings + ids; never base URL or scheme (SSRF-safe).
- AQL is passed straight through to Atlassian; we DO NOT attempt to
  parse or sanitize it. Authorisation is enforced by Atlassian using the
  caller's API token. See accepted-risks.md AR-7.
- Result paging is bounded (max_results <= 200) so a single tool call
  cannot trigger thousands of upstream pages.
"""

from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP

from ..client import AtlassianClient

_MAX_RESULTS_CEILING = 200


def register_assets_tools(
    mcp: FastMCP, client: AtlassianClient, workspace_id: str
) -> None:
    base = f"/jsm/assets/workspace/{workspace_id}/v1"

    @mcp.tool()
    async def assets_aql_search(
        aql: str,
        start_at: int = 0,
        max_results: int = 50,
        include_attributes: bool = True,
    ) -> dict[str, Any]:
        """Search Assets objects with AQL (Asset Query Language).

        Examples:
          - 'objectType = Laptop AND Owner = "user@halostudios.com"'
          - 'objectSchema = "Halo Studios Employees" AND Name LIKE "Nguyen"'
          - 'Owner.emailAddress = "v-nguyenmich@halostudios.com"'

        AQL is NOT JQL. Reference:
        https://support.atlassian.com/jira-service-management-cloud/docs/use-assets-query-language-aql/
        """
        max_results = max(1, min(int(max_results), _MAX_RESULTS_CEILING))
        return await client.post(
            f"{base}/object/aql",
            json={"qlQuery": aql},
            params={
                "startAt": int(start_at),
                "maxResults": max_results,
                "includeAttributes": str(bool(include_attributes)).lower(),
            },
        )

    @mcp.tool()
    async def assets_get_object(object_id: str) -> dict[str, Any]:
        """Fetch a single Assets object by numeric id (e.g. '12345').

        The id is the numeric primary key, not the human key (e.g. 'HSE-42').
        Use assets_aql_search with 'Key = "HSE-42"' to resolve a human key.
        """
        return await client.get(f"{base}/object/{object_id}")

    @mcp.tool()
    async def assets_get_object_attributes(object_id: str) -> Any:
        """List attribute values for a single Assets object."""
        return await client.get(f"{base}/object/{object_id}/attributes")

    @mcp.tool()
    async def assets_list_schemas() -> Any:
        """List all object schemas visible to the caller in this workspace."""
        return await client.get(f"{base}/objectschema/list")

    @mcp.tool()
    async def assets_list_object_types(schema_id: str) -> Any:
        """List all object types in a given schema (flat list).

        schema_id is the numeric id from assets_list_schemas.
        """
        return await client.get(
            f"{base}/objectschema/{schema_id}/objecttypes/flat"
        )
