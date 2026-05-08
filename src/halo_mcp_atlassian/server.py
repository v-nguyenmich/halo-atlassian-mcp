"""FastMCP server entry — `halo-atlassian`."""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from .client import AtlassianClient
from .config import Config
from .logging import configure as configure_logging
from .logging import get_logger
from .tools import register_confluence_tools, register_jira_tools


def build_server() -> FastMCP:
    cfg = Config.from_env()
    configure_logging(cfg.log_level)
    log = get_logger(__name__)

    mcp = FastMCP("halo-atlassian")

    jira = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    # NOTE: httpx 0.28+ appends absolute paths to base_url instead of
    # replacing them. Strip /wiki suffix here because all confluence tool
    # paths already start with /wiki/.
    confluence_host = cfg.confluence_base_url.removesuffix("/wiki")
    confluence = AtlassianClient(confluence_host, cfg, product="confluence")

    register_jira_tools(mcp, jira)
    register_confluence_tools(mcp, confluence, cfg)

    log.info(
        "server.ready",
        name="halo-atlassian",
        jira_base=cfg.jira_base_url,
        confluence_base=cfg.confluence_base_url,
    )
    return mcp
