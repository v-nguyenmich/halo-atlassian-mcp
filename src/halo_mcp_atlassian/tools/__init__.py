"""Tool registration entry points."""

from .jira import register_jira_tools
from .confluence import register_confluence_tools

__all__ = ["register_jira_tools", "register_confluence_tools"]
