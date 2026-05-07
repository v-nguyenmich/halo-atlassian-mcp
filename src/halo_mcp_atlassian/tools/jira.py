"""Jira tools — Phase 1 ships jira_get_issue. Phases 2/3 fill in the rest.

All tools accept only path/query parameters. The base URL is host-bound
in the AtlassianClient; tools cannot redirect requests elsewhere.
"""

from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP

from ..adf import markdown_to_adf
from ..client import AtlassianClient


def register_jira_tools(mcp: FastMCP, client: AtlassianClient) -> None:
    @mcp.tool()
    async def jira_get_issue(
        issue_key: str,
        fields: str | None = None,
        expand: str | None = None,
    ) -> dict[str, Any]:
        """Fetch a Jira issue by key (e.g. 'PROJ-123').

        fields: comma-separated field list, or '*all' for everything.
        expand: comma-separated expand options (e.g. 'renderedFields,changelog').
        """
        _require_key(issue_key)
        params: dict[str, Any] = {}
        if fields:
            params["fields"] = fields
        if expand:
            params["expand"] = expand
        return await client.get(f"/rest/api/3/issue/{issue_key}", params=params or None)

    # ----- Phase 2 stubs --------------------------------------------------

    @mcp.tool()
    async def jira_search(
        jql: str,
        fields: str | None = None,
        next_page_token: str | None = None,
        max_results: int = 50,
    ) -> dict[str, Any]:
        """Search Jira issues with JQL (REST v3 /search/jql)."""
        body: dict[str, Any] = {"jql": jql, "maxResults": max(1, min(max_results, 100))}
        if fields:
            body["fields"] = [f.strip() for f in fields.split(",") if f.strip()]
        if next_page_token:
            body["nextPageToken"] = next_page_token
        return await client.post("/rest/api/3/search/jql", json=body)

    @mcp.tool()
    async def jira_get_transitions(issue_key: str) -> dict[str, Any]:
        """List available workflow transitions for an issue."""
        _require_key(issue_key)
        return await client.get(f"/rest/api/3/issue/{issue_key}/transitions")

    @mcp.tool()
    async def jira_search_users(query: str, max_results: int = 25) -> Any:
        """Search Jira users by query (display name or email)."""
        return await client.get(
            "/rest/api/3/user/search",
            params={"query": query, "maxResults": max(1, min(max_results, 100))},
        )

    @mcp.tool()
    async def jira_get_user_groups(account_id: str) -> Any:
        """List groups for a Jira user by accountId."""
        return await client.get("/rest/api/3/user/groups", params={"accountId": account_id})

    # ----- Phase 3 writes -------------------------------------------------

    @mcp.tool()
    async def jira_add_comment(issue_key: str, body_markdown: str) -> dict[str, Any]:
        """Add a comment to an issue. body_markdown is converted to ADF."""
        _require_key(issue_key)
        return await client.post(
            f"/rest/api/3/issue/{issue_key}/comment",
            json={"body": markdown_to_adf(body_markdown)},
        )

    @mcp.tool()
    async def jira_transition_issue(
        issue_key: str, transition_id: str, comment_markdown: str | None = None
    ) -> None:
        """Transition an issue to another status."""
        _require_key(issue_key)
        payload: dict[str, Any] = {"transition": {"id": transition_id}}
        if comment_markdown:
            payload["update"] = {
                "comment": [{"add": {"body": markdown_to_adf(comment_markdown)}}]
            }
        await client.post(f"/rest/api/3/issue/{issue_key}/transitions", json=payload)

    @mcp.tool()
    async def jira_update_issue(issue_key: str, fields_json: dict[str, Any]) -> None:
        """Update an issue's fields. fields_json is the raw `fields` payload."""
        _require_key(issue_key)
        await client.put(f"/rest/api/3/issue/{issue_key}", json={"fields": fields_json})

    @mcp.tool()
    async def jira_create_issue(
        project_key: str,
        summary: str,
        issue_type: str,
        description_markdown: str | None = None,
        assignee_account_id: str | None = None,
        extra_fields_json: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Create a new Jira issue."""
        fields: dict[str, Any] = {
            "project": {"key": project_key},
            "summary": summary,
            "issuetype": {"name": issue_type},
        }
        if description_markdown:
            fields["description"] = markdown_to_adf(description_markdown)
        if assignee_account_id:
            fields["assignee"] = {"accountId": assignee_account_id}
        if extra_fields_json:
            fields.update(extra_fields_json)
        return await client.post("/rest/api/3/issue", json={"fields": fields})


def _require_key(issue_key: str) -> None:
    if not issue_key or "-" not in issue_key:
        raise ValueError(f"invalid issue_key: {issue_key!r}")
