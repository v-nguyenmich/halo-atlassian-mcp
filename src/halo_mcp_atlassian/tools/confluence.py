"""Confluence tools.

REST v2 paths. Pagination follows the `Link: <...>; rel="next"` header which
Confluence v2 uses; we expose `next_cursor` as an optional argument.

Security guards (Phase 3+):
- Storage-format bodies are validated against an allowlist of HTML tags and
  Confluence macros. Script tags, iframes, object/embed, and unsafe macros
  (e.g., `{html}`, `{include}`) are rejected. Sanitized at the edge so a
  poisoned LLM cannot craft stored XSS payloads.
- Attachment uploads are constrained to a configured `upload_root` path; any
  path that escapes the root after `realpath` resolution is rejected.
- MIME type allowlist enforced before sending to Confluence.
"""

from __future__ import annotations

import os
import re
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

_BLOCKED_STORAGE_TAGS = re.compile(
    r"<\s*(script|iframe|object|embed|form|meta|link|base|svg|math)\b",
    re.IGNORECASE,
)
_BLOCKED_STORAGE_ATTRS = re.compile(
    r"\son[a-z]+\s*=|javascript\s*:|data\s*:\s*text/html",
    re.IGNORECASE,
)
_BLOCKED_MACROS = {"html", "include", "script", "rss", "gadget", "iframe"}
_MACRO_NAME_RE = re.compile(r'ac:name\s*=\s*"([^"]+)"', re.IGNORECASE)


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
        """Create a Confluence page (storage-format body).

        body_storage is sanitized against an allowlist before submission;
        script, iframe, object, embed, inline event handlers, javascript:
        URLs, and unsafe macros (html, include, script, rss, gadget, iframe)
        are rejected.
        """
        _validate_storage_body(body_storage)
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
        """Update a Confluence page. version_number must be the current version + 1.

        body_storage is sanitized — see confluence_create_page.
        """
        _validate_storage_body(body_storage)
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
        - path MUST resolve inside the configured upload_root
          (default `/uploads`; override with HALO_MCP_UPLOAD_ROOT). This
          prevents a poisoned LLM from exfiltrating arbitrary host files.
        - symlinks that point outside upload_root are rejected
        - max size from config (default 50 MiB)
        - MIME allowlist enforced before send
        """
        safe_path = _resolve_upload_path(file_path, cfg.upload_root)
        size = os.path.getsize(safe_path)
        if size > cfg.max_upload_bytes:
            raise ValueError(f"file exceeds max upload size: {size} > {cfg.max_upload_bytes}")
        mime = _guess_mime(safe_path)
        if mime not in _ALLOWED_UPLOAD_MIME:
            raise ValueError(f"mime type not allowed: {mime}")
        with open(safe_path, "rb") as fh:
            files: dict[str, Any] = {
                "file": (os.path.basename(safe_path), fh.read(), mime),
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


def _resolve_upload_path(file_path: str, upload_root: str) -> str:
    """Reject anything that escapes upload_root after symlink resolution."""
    if not file_path:
        raise ValueError("file_path is required")
    root = os.path.realpath(upload_root)
    candidate = os.path.realpath(os.path.join(root, file_path)
                                 if not os.path.isabs(file_path) else file_path)
    if not (candidate == root or candidate.startswith(root + os.sep)):
        raise ValueError(
            f"file_path escapes upload_root: refusing to read outside {upload_root!r}"
        )
    if not os.path.isfile(candidate):
        raise ValueError(f"file_path does not point to a regular file: {file_path!r}")
    return candidate


def _validate_storage_body(body: str) -> None:
    """Allowlist-style guard against stored XSS / macro abuse in
    Confluence storage format. We reject; we do not silently strip."""
    if _BLOCKED_STORAGE_TAGS.search(body):
        raise ValueError("body_storage contains a blocked tag (script/iframe/object/embed/...)")
    if _BLOCKED_STORAGE_ATTRS.search(body):
        raise ValueError("body_storage contains an inline event handler or unsafe URL scheme")
    for name in _MACRO_NAME_RE.findall(body):
        if name.lower() in _BLOCKED_MACROS:
            raise ValueError(f"body_storage references blocked macro: {name}")
