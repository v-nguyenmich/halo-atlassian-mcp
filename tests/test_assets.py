"""Tests for Assets tool registration and HTTP behavior."""

from __future__ import annotations

import httpx
import pytest
import respx
from mcp.server.fastmcp import FastMCP

from halo_mcp_atlassian.client import AtlassianClient
from halo_mcp_atlassian.config import Config
from halo_mcp_atlassian.tools.assets import (
    AssetsWriteDenied,
    register_assets_tools,
)

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


# ---- write surface ---------------------------------------------------


def test_write_tools_not_registered_when_disabled(assets_client: AtlassianClient) -> None:
    mcp = FastMCP("t")
    register_assets_tools(mcp, assets_client, WS)  # write_enabled defaults to False
    names = _registered_tool_names(mcp)
    for tool in (
        "assets_create_object",
        "assets_update_object",
        "assets_delete_object",
        "assets_list_object_type_attributes",
    ):
        assert tool not in names


def test_write_tools_not_registered_when_allowlist_empty(assets_client: AtlassianClient) -> None:
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset()
    )
    names = _registered_tool_names(mcp)
    assert "assets_create_object" not in names


def test_write_tools_register_when_enabled(assets_client: AtlassianClient) -> None:
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    names = _registered_tool_names(mcp)
    assert {
        "assets_create_object",
        "assets_update_object",
        "assets_delete_object",
        "assets_list_object_type_attributes",
    }.issubset(names)


@pytest.mark.asyncio
@respx.mock
async def test_create_object_blocked_when_object_type_not_allowed(assets_client: AtlassianClient) -> None:
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_create_object")
    with pytest.raises(AssetsWriteDenied):
        await tool.fn(object_type_id="999", attributes={"1": "x"})


@pytest.mark.asyncio
@respx.mock
async def test_create_object_formats_attributes(assets_client: AtlassianClient) -> None:
    route = respx.post(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/create"
    ).mock(return_value=httpx.Response(200, json={"id": "555", "objectKey": "AMT-555"}))
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_create_object")
    out = await tool.fn(
        object_type_id="42",
        attributes={"1": "Hello", "2": ["a", "b"], "3": True},
    )
    assert out["objectKey"] == "AMT-555"
    import json as _json
    body = _json.loads(route.calls[0].request.content)
    assert body["objectTypeId"] == "42"
    assert body["hasAvatar"] is False
    by_id = {a["objectTypeAttributeId"]: a["objectAttributeValues"] for a in body["attributes"]}
    assert by_id["1"] == [{"value": "Hello"}]
    assert by_id["2"] == [{"value": "a"}, {"value": "b"}]
    assert by_id["3"] == [{"value": "true"}]


@pytest.mark.asyncio
@respx.mock
async def test_update_object_checks_object_type_allowlist(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(200, json={"id": "777", "objectType": {"id": "999"}}))
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_update_object")
    with pytest.raises(AssetsWriteDenied):
        await tool.fn(object_id="777", attributes={"1": "x"})


@pytest.mark.asyncio
@respx.mock
async def test_update_object_calls_put_when_allowed(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(200, json={"id": "777", "objectType": {"id": "42"}}))
    put_route = respx.put(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(200, json={"id": "777"}))
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_update_object")
    await tool.fn(object_id="777", attributes={"5": "new value"})
    assert put_route.called
    import json as _json
    body = _json.loads(put_route.calls[0].request.content)
    assert body["objectTypeId"] == "42"
    assert body["attributes"][0]["objectTypeAttributeId"] == "5"


@pytest.mark.asyncio
@respx.mock
async def test_delete_requires_matching_confirm_key(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(
        200, json={"id": "777", "objectKey": "AMT-777", "objectType": {"id": "42"}}
    ))
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_delete_object")
    with pytest.raises(AssetsWriteDenied):
        await tool.fn(object_id="777", confirm_object_key="AMT-WRONG")


@pytest.mark.asyncio
@respx.mock
async def test_delete_succeeds_when_key_matches(assets_client: AtlassianClient) -> None:
    respx.get(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(
        200, json={"id": "777", "objectKey": "AMT-777", "objectType": {"id": "42"}}
    ))
    del_route = respx.delete(
        f"{ASSETS_BASE}/jsm/assets/workspace/{WS}/v1/object/777"
    ).mock(return_value=httpx.Response(204))
    mcp = FastMCP("t")
    register_assets_tools(
        mcp, assets_client, WS, write_enabled=True, write_object_types=frozenset({"42"})
    )
    tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "assets_delete_object")
    out = await tool.fn(object_id="777", confirm_object_key="AMT-777")
    assert del_route.called
    assert out == {"deleted": True, "objectId": "777", "objectKey": "AMT-777"}
