import os

import pytest

os.environ.setdefault("ATLASSIAN_JIRA_URL", "https://example.atlassian.net")
os.environ.setdefault("ATLASSIAN_CONFLUENCE_URL", "https://example.atlassian.net")
os.environ.setdefault("ATLASSIAN_EMAIL", "svc@example.com")
os.environ.setdefault("ATLASSIAN_API_TOKEN", "test-token")


@pytest.fixture
def cfg():
    from halo_mcp_atlassian.config import Config
    return Config.from_env()
