"""Server build with sync + best-effort assets discovery.

Assets registration is graceful: if discovery fails (no JSM access, network
issue, etc.), Jira + Confluence still come up. Tools are only registered
when we have a workspace id so we don't expose tools that always 404.
"""

from __future__ import annotations

import asyncio
from typing import Any

from mcp.server.fastmcp import FastMCP

from .client import AtlassianClient
from .config import Config
from .logging import configure as configure_logging
from .logging import get_logger
from .tools import (
    register_assets_tools,
    register_confluence_tools,
    register_jira_tools,
)

log = get_logger(__name__)


async def _discover_assets_workspace(jira: AtlassianClient) -> str | None:
    """Resolve workspace id via the JSM REST endpoint on the Jira host.

    Returns None on any failure (no JSM, no Assets, network error, etc.).
    """
    try:
        data: Any = await jira.get("/rest/servicedeskapi/assets/workspace")
        values = (data or {}).get("values") or []
        if values and isinstance(values[0], dict):
            ws = values[0].get("workspaceId")
            if isinstance(ws, str) and ws:
                return ws
    except Exception as exc:
        log.warning("assets.discover_failed", error=str(exc))
    return None


def build_server() -> FastMCP:
    cfg = Config.from_env()
    configure_logging(cfg.log_level)

    mcp = FastMCP("halo-atlassian")

    jira = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    # NOTE: httpx 0.28+ appends absolute paths to base_url instead of
    # replacing them. Strip /wiki suffix here because all confluence tool
    # paths already start with /wiki/.
    confluence_host = cfg.confluence_base_url.removesuffix("/wiki")
    confluence = AtlassianClient(confluence_host, cfg, product="confluence")

    register_jira_tools(mcp, jira)
    register_confluence_tools(mcp, confluence, cfg)

    workspace_id = cfg.assets_workspace_id
    if workspace_id is None:
        workspace_id = asyncio.run(_discover_assets_workspace(jira))

    assets_enabled = False
    if workspace_id:
        assets = AtlassianClient(cfg.assets_api_base, cfg, product="assets")
        register_assets_tools(
            mcp,
            assets,
            workspace_id,
            write_enabled=cfg.assets_write_enabled,
            write_object_types=cfg.assets_write_object_types,
        )
        assets_enabled = True

    log.info(
        "server.ready",
        name="halo-atlassian",
        jira_base=cfg.jira_base_url,
        confluence_base=cfg.confluence_base_url,
        assets_enabled=assets_enabled,
        assets_workspace_id=workspace_id if assets_enabled else None,
        assets_write_enabled=cfg.assets_write_enabled and bool(cfg.assets_write_object_types),
        assets_write_allowlist=sorted(cfg.assets_write_object_types) if cfg.assets_write_enabled else [],
    )
    return mcp
