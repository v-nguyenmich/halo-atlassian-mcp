# Tool reference (v1)

All tools are registered on the FastMCP server named `halo-atlassian`.

## Jira (REST v3)
| Tool | Method | Path |
|---|---|---|
| jira_search | POST | /rest/api/3/search/jql |
| jira_get_issue | GET | /rest/api/3/issue/{key} |
| jira_get_transitions | GET | /rest/api/3/issue/{key}/transitions |
| jira_search_users | GET | /rest/api/3/user/search |
| jira_get_user_groups | GET | /rest/api/3/user/groups |
| jira_add_comment | POST | /rest/api/3/issue/{key}/comment |
| jira_transition_issue | POST | /rest/api/3/issue/{key}/transitions |
| jira_update_issue | PUT | /rest/api/3/issue/{key} |
| jira_create_issue | POST | /rest/api/3/issue |

## Confluence (REST v2 + v1 search fallback)
| Tool | Method | Path |
|---|---|---|
| confluence_search | GET | /wiki/rest/api/search |
| confluence_get_page | GET | /wiki/api/v2/pages/{id} |
| confluence_get_page_by_title | GET | /wiki/api/v2/pages |
| confluence_get_attachments | GET | /wiki/api/v2/pages/{id}/attachments |
| confluence_create_page | POST | /wiki/api/v2/pages |
| confluence_update_page | PUT | /wiki/api/v2/pages/{id} |
| confluence_upload_attachment | POST (multipart) | /wiki/rest/api/content/{id}/child/attachment |

## Input contract
- No tool accepts a URL, scheme, or host. Only ids, keys, and query/body fields.
- Markdown bodies (comments, descriptions) are converted to ADF in `adf.py`.
- Confluence pages use `storage` representation in v1; HTML rendering is a Phase 2 follow-up.
