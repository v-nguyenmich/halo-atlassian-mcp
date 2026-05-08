"""Entry point: `python -m halo_mcp_atlassian` or `halo-mcp-atlassian`.

Supports a `--check` mode used by the wrapper for staged-rollout health gating.
The check performs one cheap authenticated round-trip against Jira's /myself
endpoint and exits 0 on success / non-zero on any failure. It does NOT start
the MCP server. The wrapper invokes `--check` against a candidate image and
falls back to the previous pinned image if it fails.
"""

from __future__ import annotations

import asyncio
import sys

from .client import AtlassianClient
from .config import Config, ConfigError
from .server import build_server


async def _health_check() -> int:
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"halo-mcp-atlassian: config error: {exc}", file=sys.stderr)
        return 2
    client = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    try:
        await client.get("/rest/api/3/myself")
        print("halo-mcp-atlassian: health ok", file=sys.stderr)
        return 0
    except Exception as exc:
        print(f"halo-mcp-atlassian: health failed: {exc}", file=sys.stderr)
        return 1
    finally:
        await client.aclose()


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        sys.exit(asyncio.run(_health_check()))
    server = build_server()
    server.run()


if __name__ == "__main__":
    main()
