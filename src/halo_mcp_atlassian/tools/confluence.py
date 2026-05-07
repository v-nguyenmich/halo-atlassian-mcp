"""Confluence tools — Phase 1 wires the registry; Phase 2/3 fill in bodies.

REST v2 paths. Pagination follows the `Link: <...>; rel="next"` header which
Confluence v2 uses; we expose `next_cursor` as an optional argument.
"""

from __future__ import annotations

import os
from typing import Any

from mcp.server.fastmcp import FastMCP

from ..client import AtlassianClient
from ..config import Config

_ALLOWED_UPLOAD_MIME = {
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
    "application/pdf", "text/plain", "text/markdown",
    "application/zip", "application/json",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
}


def register_confluence_tools(mcp: FastMCP, client: AtlassianClient, cfg: Config) -> None:
    @mcp.tool()
    async def confluence_search(
        cql: str, limit: int = 25, cursor: str | None = None
    ) -> dict[str, Any]:
        """Search Confluence with CQL (v1 search endpoint; v2 has no equivalent)."""
        params: dict[str, Any] = {"cql": cql, "limit": max(1, min(limit, 100))}
        if cursor:
            params["cursor"] = cursor
        return await client.get("/wiki/rest/api/search", params=params)

    @mcp.tool()
    async def confluence_get_page(
        page_id: str, body_format: str = "storage"
    ) -> dict[str, Any]:
        """Fetch a Confluence page by id. body_format: storage|atlas_doc_format|view."""
        return await client.get(
            f"/wiki/api/v2/pages/{page_id}", params={"body-format": body_format}
        )

    @mcp.tool()
    async def confluence_get_page_by_title(
        space_id: str, title: str, body_format: str = "storage"
    ) -> dict[str, Any]:
        """Find a page by exact title within a space."""
        return await client.get(
            "/wiki/api/v2/pages",
            params={"space-id": space_id, "title": title, "body-format": body_format},
        )

    @mcp.tool()
    async def confluence_get_attachments(
        page_id: str, limit: int = 25, cursor: str | None = None
    ) -> dict[str, Any]:
        """List attachments for a page."""
        params: dict[str, Any] = {"limit": max(1, min(limit, 250))}
        if cursor:
            params["cursor"] = cursor
        return await client.get(f"/wiki/api/v2/pages/{page_id}/attachments", params=params)

    # ----- Phase 3 writes -------------------------------------------------

    @mcp.tool()
    async def confluence_create_page(
        space_id: str,
        title: str,
        body_storage: str,
        parent_id: str | None = None,
    ) -> dict[str, Any]:
        """Create a Confluence page (storage-format body)."""
        body: dict[str, Any] = {
            "spaceId": space_id,
            "status": "current",
            "title": title,
            "body": {"representation": "storage", "value": body_storage},
        }
        if parent_id:
            body["parentId"] = parent_id
        return await client.post("/wiki/api/v2/pages", json=body)

    @mcp.tool()
    async def confluence_update_page(
        page_id: str,
        title: str,
        body_storage: str,
        version_number: int,
    ) -> dict[str, Any]:
        """Update a Confluence page. version_number must be the current version + 1."""
        return await client.put(
            f"/wiki/api/v2/pages/{page_id}",
            json={
                "id": page_id,
                "status": "current",
                "title": title,
                "body": {"representation": "storage", "value": body_storage},
                "version": {"number": version_number},
            },
        )

    @mcp.tool()
    async def confluence_upload_attachment(
        page_id: str,
        file_path: str,
        comment: str | None = None,
    ) -> dict[str, Any]:
        """Upload (or new-version) an attachment from a local readable path.

        Enforced guards:
        - max size from config (default 50 MiB)
        - MIME allowlist
        - path must be readable by the runtime user; container should mount :ro
        """
        size = os.path.getsize(file_path)
        if size > cfg.max_upload_bytes:
            raise ValueError(f"file exceeds max upload size: {size} > {cfg.max_upload_bytes}")
        mime = _guess_mime(file_path)
        if mime not in _ALLOWED_UPLOAD_MIME:
            raise ValueError(f"mime type not allowed: {mime}")
        with open(file_path, "rb") as fh:
            files: dict[str, Any] = {
                "file": (os.path.basename(file_path), fh.read(), mime),
            }
            if comment:
                files["comment"] = (None, comment)
            return await client.post_multipart(
                f"/wiki/rest/api/content/{page_id}/child/attachment",
                files=files,
            )


def _guess_mime(path: str) -> str:
    import mimetypes
    mime, _ = mimetypes.guess_type(path)
    return mime or "application/octet-stream"
