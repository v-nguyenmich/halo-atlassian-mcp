"""Tests for Assets tool registration and HTTP behavior."""

from __future__ import annotations

import httpx
import pytest
import respx
from mcp.server.fastmcp import FastMCP

from halo_mcp_atlassian.client import AtlassianClient
from halo_mcp_atlassian.config import Config
from halo_mcp_atlassian.tools.assets import register_assets_tools

WS = "ba23864d-bd69-47b4-a6b6-3ca1b60f2968"
ASSETS_BASE = "https://api.atlassian.com"


@pytest.fixture
def cfg() -> Config:
    return Config(
        jira_base_url="https://example.atlassian.net",
        confluence_base_url="https://example.atlassian.net/wiki",
        auth_email="x@example.com",
        auth_token="t",
    )


@pytest.fixture
def assets_client(cfg: Config) -> AtlassianClient:
    return AtlassianClient(ASSETS_BASE, cfg, product="assets")


def _registered_tool_names(mcp: FastMCP) -> set[str]:
    return {t.name for t in mcp._tool_manager.list_tools()}


def test_assets_tools_register(assets_client: AtlassianClient) -> None:
    mcp = FastMCP("test")
    register_assets_tools(mcp, assets_client, WS)
    names = _registered_tool_names(mcp)
    assert names == {
        "assets_aql_search",
        "assets_get_object",
        "assets_get_object_attributes",
        "assets_list_schemas",
        "assets_list_object_types",
    }


def test_assets_url_build_uses_api_atlassian_host(cfg: Config) -> None:
    """Regression guard: assets requests MUST hit api.atlassian.com,
    not the *.atlassian.net Jira host."""
    c = AtlassianClient(ASSETS_BASE, cfg, product="assets")
    req = c._client.build_request("POST", f"/jsm/assets/workspace/{WS}/v1/object/aql")
    assert str(req.url) == f"https://api.atlassian.com/jsm/assets/workspace/{WS}/v1/object/aql"
    assert "atlassian.net" not in str(req.url)


@pytest.mark.asyncio
@respx.mock
async def test_aql_search_max_results_capped(assets_client: AtlassianClient) -> None:
    route = respx.post(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/aql"
    ).mock(return_value=httpx.Response(200, json={"values": [], "total": 0}))

    mcp = FastMCP("t")
    register_assets_tools(mcp, assets_client, WS)
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_aql_search")
    # Request 10000; ceiling is 200
    await tool.fn(aql="objectType = Laptop", max_results=10000)
    sent = route.calls[0].request
    # query string is bytes in httpx; decode and assert
    assert b"maxResults=200" in sent.url.query
    assert b"startAt=0" in sent.url.query


@pytest.mark.asyncio
@respx.mock
async def test_aql_search_passes_qlquery_in_body(assets_client: AtlassianClient) -> None:
    route = respx.post(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/aql"
    ).mock(return_value=httpx.Response(200, json={"values": [], "total": 0}))

    mcp = FastMCP("t")
    register_assets_tools(mcp, assets_client, WS)
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_aql_search")
    await tool.fn(aql='Owner = "x@example.com"')
    body = route.calls[0].request.content
    assert b'"qlQuery"' in body
    assert b'Owner = ' in body


@pytest.mark.asyncio
@respx.mock
async def test_get_object_uses_numeric_id_path(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/12345"
    ).mock(return_value=httpx.Response(200, json={"id": "12345"}))
    mcp = FastMCP("t")
    register_assets_tools(mcp, assets_client, WS)
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_get_object")
    out = await tool.fn(object_id="12345")
    assert out == {"id": "12345"}


@pytest.mark.asyncio
@respx.mock
async def test_list_schemas(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/objectschema/list"
    ).mock(return_value=httpx.Response(200, json={"values": [{"id": "1", "name": "Services"}]}))
    mcp = FastMCP("t")
    register_assets_tools(mcp, assets_client, WS)
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_list_schemas")
    out = await tool.fn()
    assert out["values"][0]["name"] == "Services"
