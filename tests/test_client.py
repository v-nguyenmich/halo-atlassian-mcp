import httpx
import pytest
import respx

from halo_mcp_atlassian.client import AtlassianClient, AtlassianHTTPError


@pytest.mark.asyncio
@respx.mock
async def test_get_issue_returns_json(cfg):
    respx.get("https://example.atlassian.net/rest/api/3/issue/PROJ-1").mock(
        return_value=httpx.Response(200, json={"key": "PROJ-1"})
    )
    c = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    try:
        data = await c.get("/rest/api/3/issue/PROJ-1")
        assert data == {"key": "PROJ-1"}
    finally:
        await c.aclose()


@pytest.mark.asyncio
@respx.mock
async def test_retries_on_429_then_succeeds(cfg):
    route = respx.get("https://example.atlassian.net/rest/api/3/issue/PROJ-1")
    route.side_effect = [
        httpx.Response(429, headers={"retry-after": "0"}),
        httpx.Response(200, json={"key": "PROJ-1"}),
    ]
    c = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    try:
        data = await c.get("/rest/api/3/issue/PROJ-1")
        assert data == {"key": "PROJ-1"}
    finally:
        await c.aclose()


@pytest.mark.asyncio
@respx.mock
async def test_raises_on_4xx(cfg):
    respx.get("https://example.atlassian.net/rest/api/3/issue/X-1").mock(
        return_value=httpx.Response(404, json={"errorMessages": ["not found"]})
    )
    c = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    try:
        with pytest.raises(AtlassianHTTPError) as excinfo:
            await c.get("/rest/api/3/issue/X-1")
        assert excinfo.value.status == 404
    finally:
        await c.aclose()


@pytest.mark.asyncio
@respx.mock
async def test_authorization_header_is_sent(cfg):
    captured = {}

    def handler(request):
        captured["auth"] = request.headers.get("authorization", "")
        return httpx.Response(200, json={})

    respx.get("https://example.atlassian.net/rest/api/3/myself").mock(side_effect=handler)
    c = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    try:
        await c.get("/rest/api/3/myself")
        assert captured["auth"].startswith("Basic ")
    finally:
        await c.aclose()
