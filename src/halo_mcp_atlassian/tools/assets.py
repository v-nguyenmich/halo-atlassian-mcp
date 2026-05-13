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

Write tools (create/update/delete) are OFF by default. They register only
when HALO_MCP_ASSETS_WRITE=1 AND HALO_MCP_ASSETS_WRITE_OBJECT_TYPES is a
non-empty allowlist of numeric object-type ids. Delete additionally
requires the caller to echo back the live objectKey as confirmation.
"""

from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP

from ..client import AtlassianClient

_MAX_RESULTS_CEILING = 200


class AssetsWriteDenied(RuntimeError):
    """Raised when a write is rejected by the local allowlist guard."""


def register_assets_tools(
    mcp: FastMCP,
    client: AtlassianClient,
    workspace_id: str,
    *,
    write_enabled: bool = False,
    write_object_types: frozenset[str] = frozenset(),
) -> None:
    base = f"/jsm/assets/workspace/{workspace_id}/v1"

    @mcp.tool()
    async def assets_aql_search(
        aql: str,
        start_at: int = 0,
        max_results: int = 50,
        include_attributes: bool = True,
        compact: bool = False,
    ) -> dict[str, Any]:
        """Search Assets objects with AQL (Asset Query Language).

        Examples:
          - 'objectType = Laptop AND Owner = "user@halostudios.com"'
          - 'objectSchema = "Halo Studios Employees" AND Name LIKE "Nguyen"'
          - 'Owner.emailAddress = "v-nguyenmich@halostudios.com"'

        AQL is NOT JQL. Reference:
        https://support.atlassian.com/jira-service-management-cloud/docs/use-assets-query-language-aql/

        compact=True forces include_attributes=False AND strips per-row fields
        down to {id, objectKey, label, objectType:{id,name}}. Use compact for
        list/browse queries to keep responses ~100x smaller (avoids tool-output
        truncation on result sets > a few rows). Use compact=False (default)
        when you actually need attribute values or avatar/schema metadata.
        """
        max_results = max(1, min(int(max_results), _MAX_RESULTS_CEILING))
        if compact:
            include_attributes = False
        data = await client.post(
            f"{base}/object/aql",
            json={"qlQuery": aql},
            params={
                "startAt": int(start_at),
                "maxResults": max_results,
                "includeAttributes": str(bool(include_attributes)).lower(),
            },
        )
        if compact and isinstance(data, dict):
            data = _compact_aql_response(data)
        return data

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

    @mcp.tool()
    async def assets_list_object_type_attributes(object_type_id: str) -> Any:
        """List attribute schema (id, name, type) for an object type.

        Read-only. Use this to map the numeric attribute ids returned by
        assets_get_object / assets_aql_search(include_attributes=true) into
        human-readable names. Also required to discover the attribute_ids
        that assets_create_object / assets_update_object expect.
        """
        return await client.get(
            f"{base}/objecttype/{object_type_id}/attributes"
        )

    if not (write_enabled and write_object_types):
        return

    @mcp.tool()
    async def assets_create_object(
        object_type_id: str,
        attributes: dict[str, Any],
        has_avatar: bool = False,
    ) -> dict[str, Any]:
        """Create a new Assets object.

        object_type_id MUST be in HALO_MCP_ASSETS_WRITE_OBJECT_TYPES allowlist.
        attributes is a dict {attribute_id: value | [value, ...]}; values are
        coerced into Atlassian's verbose objectAttributeValues shape.

        Use assets_list_object_type_attributes(object_type_id) to discover
        attribute_ids and their names.
        """
        _enforce_object_type_allowed(str(object_type_id), write_object_types)
        return await client.post(
            f"{base}/object/create",
            json={
                "objectTypeId": str(object_type_id),
                "attributes": _format_attributes(attributes),
                "hasAvatar": bool(has_avatar),
            },
        )

    @mcp.tool()
    async def assets_update_object(
        object_id: str,
        attributes: dict[str, Any],
    ) -> dict[str, Any]:
        """Update attributes on an existing Assets object.

        The object's objectType.id must be in the
        HALO_MCP_ASSETS_WRITE_OBJECT_TYPES allowlist. attributes is merged;
        attributes not listed are left untouched. To clear a value, pass
        an empty list for that attribute id.
        """
        existing = await client.get(f"{base}/object/{object_id}")
        otid = _extract_object_type_id(existing)
        _enforce_object_type_allowed(otid, write_object_types)
        return await client.put(
            f"{base}/object/{object_id}",
            json={
                "objectTypeId": otid,
                "attributes": _format_attributes(attributes),
            },
        )

    @mcp.tool()
    async def assets_delete_object(
        object_id: str,
        confirm_object_key: str,
    ) -> dict[str, Any]:
        """Delete an Assets object.

        confirm_object_key MUST equal the live objectKey (e.g. 'AMT-10977').
        This is a destructive irreversible operation; the double-confirm is
        a guard against poisoned-LLM mass-delete. The object's type must
        also be in the allowlist.
        """
        existing = await client.get(f"{base}/object/{object_id}")
        live_key = (existing or {}).get("objectKey") or ""
        if not confirm_object_key or confirm_object_key.strip() != live_key:
            raise AssetsWriteDenied(
                f"confirm_object_key did not match live objectKey for id={object_id}"
            )
        otid = _extract_object_type_id(existing)
        _enforce_object_type_allowed(otid, write_object_types)
        await client.delete(f"{base}/object/{object_id}")
        return {"deleted": True, "objectId": str(object_id), "objectKey": live_key}


def _enforce_object_type_allowed(
    object_type_id: str, allowlist: frozenset[str]
) -> None:
    if object_type_id not in allowlist:
        raise AssetsWriteDenied(
            f"objectTypeId {object_type_id!r} is not in the write allowlist; "
            f"allowed={sorted(allowlist)}"
        )


def _extract_object_type_id(obj: Any) -> str:
    """Pull objectType.id from a GET /object/{id} response."""
    ot = (obj or {}).get("objectType") or {}
    otid = ot.get("id")
    if otid is None:
        raise AssetsWriteDenied("could not determine objectType.id from object")
    return str(otid)


def _format_attributes(attrs: dict[str, Any]) -> list[dict[str, Any]]:
    """Convert {attr_id: value | [values]} into Assets API verbose form."""
    out: list[dict[str, Any]] = []
    for attr_id, val in (attrs or {}).items():
        values = val if isinstance(val, list) else [val]
        out.append(
            {
                "objectTypeAttributeId": str(attr_id),
                "objectAttributeValues": [{"value": _stringify(v)} for v in values],
            }
        )
    return out


def _stringify(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


_AQL_TOP_KEEP = ("startAt", "maxResults", "total", "isLast", "pageSize", "pageObjectSize")
_AQL_ROW_KEEP = ("id", "objectKey", "label")


def _compact_aql_response(data: dict[str, Any]) -> dict[str, Any]:
    """Strip an AQL search response down to identifying fields.

    Keeps top-level paging metadata. For each row, keeps only id, objectKey,
    label, and a flattened {id,name} object type. Drops avatar URLs, schema
    blobs, attributes, and per-attribute references.
    """
    out: dict[str, Any] = {k: data[k] for k in _AQL_TOP_KEEP if k in data}
    rows = data.get("values") or []
    compact_rows: list[dict[str, Any]] = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        row = {k: r[k] for k in _AQL_ROW_KEEP if k in r}
        ot = r.get("objectType") or {}
        if isinstance(ot, dict):
            row["objectType"] = {
                "id": ot.get("id"),
                "name": ot.get("name"),
            }
        compact_rows.append(row)
    out["values"] = compact_rows
    return out
