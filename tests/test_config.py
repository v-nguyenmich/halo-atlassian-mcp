
import pytest

from halo_mcp_atlassian.config import Config, ConfigError


def test_rejects_non_atlassian_host(monkeypatch):
    monkeypatch.setenv("ATLASSIAN_JIRA_URL", "https://evil.example.com")
    monkeypatch.setenv("ATLASSIAN_CONFLUENCE_URL", "https://example.atlassian.net")
    monkeypatch.setenv("ATLASSIAN_EMAIL", "x@y.com")
    monkeypatch.setenv("ATLASSIAN_API_TOKEN", "t")
    with pytest.raises(ConfigError):
        Config.from_env()


def test_rejects_http_scheme(monkeypatch):
    monkeypatch.setenv("ATLASSIAN_JIRA_URL", "http://x.atlassian.net")
    monkeypatch.setenv("ATLASSIAN_CONFLUENCE_URL", "https://x.atlassian.net")
    monkeypatch.setenv("ATLASSIAN_EMAIL", "x@y.com")
    monkeypatch.setenv("ATLASSIAN_API_TOKEN", "t")
    with pytest.raises(ConfigError):
        Config.from_env()


def test_loads_defaults(monkeypatch):
    monkeypatch.setenv("ATLASSIAN_JIRA_URL", "https://x.atlassian.net/")
    monkeypatch.setenv("ATLASSIAN_CONFLUENCE_URL", "https://x.atlassian.net/")
    monkeypatch.setenv("ATLASSIAN_EMAIL", "x@y.com")
    monkeypatch.setenv("ATLASSIAN_API_TOKEN", "t")
    c = Config.from_env()
    assert c.jira_base_url == "https://x.atlassian.net"
    assert c.request_timeout_s == 30.0
