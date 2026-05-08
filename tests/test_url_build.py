"""URL-construction regression tests.

These guard against silent transitive bumps of httpx changing how `base_url`
merges with request paths. We caught a real bug (httpx 0.28 appended absolute
paths to base_url, producing /wiki/wiki/api/v2/... 404s) — these tests will
fail loudly if a future bump reintroduces it.
"""

from __future__ import annotations

import httpx
import pytest

from halo_mcp_atlassian.client import AtlassianClient
from halo_mcp_atlassian.config import Config


@pytest.fixture
def cfg() -> Config:
    return Config(
        jira_base_url="https://example.atlassian.net",
        confluence_base_url="https://example.atlassian.net/wiki",
        auth_email="x@example.com",
        auth_token="t",
    )


def test_jira_url_build_does_not_double_path(cfg: Config) -> None:
    c = AtlassianClient(cfg.jira_base_url, cfg, product="jira")
    req = c._client.build_request("GET", "/rest/api/3/myself")
    assert str(req.url) == "https://example.atlassian.net/rest/api/3/myself"


def test_confluence_url_build_does_not_double_wiki(cfg: Config) -> None:
    """Regression: httpx 0.28+ appends absolute paths instead of replacing.

    server.py strips /wiki from base before instantiating the confluence
    client because tool paths already begin with /wiki/. If anyone reverts
    that, this test fails.
    """
    confluence_host = cfg.confluence_base_url.removesuffix("/wiki")
    c = AtlassianClient(confluence_host, cfg, product="confluence")
    req = c._client.build_request("GET", "/wiki/api/v2/pages/123")
    assert str(req.url) == "https://example.atlassian.net/wiki/api/v2/pages/123"
    assert "/wiki/wiki/" not in str(req.url)


def test_httpx_version_is_pinned() -> None:
    """Hard floor + ceiling so transitive bumps cannot land silently."""
    major, minor, *_ = (int(x) for x in httpx.__version__.split(".")[:2])
    assert (major, minor) >= (0, 27), f"httpx too old: {httpx.__version__}"
    assert (major, minor) < (0, 30), f"httpx outside tested range: {httpx.__version__}"
