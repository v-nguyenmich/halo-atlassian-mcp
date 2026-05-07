"""Runtime configuration loaded from environment.

All values are read once at startup. Tool inputs never override host/scheme;
only path/query parameters. This is the SSRF guard.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import urlparse


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Config:
    jira_base_url: str
    confluence_base_url: str
    auth_email: str
    auth_token: str
    request_timeout_s: float = 30.0
    max_upload_bytes: int = 50 * 1024 * 1024  # 50 MiB
    upload_root: str = "/uploads"
    log_level: str = "INFO"

    @staticmethod
    def from_env() -> "Config":
        jira = _require("ATLASSIAN_JIRA_URL")
        conf = _require("ATLASSIAN_CONFLUENCE_URL")
        for label, url in (("jira", jira), ("confluence", conf)):
            parsed = urlparse(url)
            if parsed.scheme != "https" or not parsed.netloc.endswith(".atlassian.net"):
                raise ConfigError(
                    f"{label} URL must be https://<tenant>.atlassian.net (got {url!r})"
                )
        return Config(
            jira_base_url=jira.rstrip("/"),
            confluence_base_url=conf.rstrip("/"),
            auth_email=_require("ATLASSIAN_EMAIL"),
            auth_token=_require("ATLASSIAN_API_TOKEN"),
            request_timeout_s=float(os.getenv("HALO_MCP_TIMEOUT_S", "30")),
            max_upload_bytes=int(os.getenv("HALO_MCP_MAX_UPLOAD_BYTES", str(50 * 1024 * 1024))),
            upload_root=os.getenv("HALO_MCP_UPLOAD_ROOT", "/uploads"),
            log_level=os.getenv("HALO_MCP_LOG_LEVEL", "INFO"),
        )


def _require(name: str) -> str:
    val = os.getenv(name)
    if not val:
        raise ConfigError(f"Required environment variable {name} is not set")
    return val
