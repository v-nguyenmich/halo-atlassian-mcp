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

## Assets / JSM (REST v1, host: api.atlassian.com)
Auto-discovers workspace id at startup via `/rest/servicedeskapi/assets/workspace`
on the Jira host. Pin explicitly with `ATLASSIAN_ASSETS_WORKSPACE_ID` to skip
discovery. If discovery fails, Assets tools are not registered (Jira + Confluence
still come up).

| Tool | Method | Path |
|---|---|---|
| assets_aql_search | POST | /jsm/assets/workspace/{ws}/v1/object/aql |
| assets_get_object | GET | /jsm/assets/workspace/{ws}/v1/object/{id} |
| assets_get_object_attributes | GET | /jsm/assets/workspace/{ws}/v1/object/{id}/attributes |
| assets_list_schemas | GET | /jsm/assets/workspace/{ws}/v1/objectschema/list |
| assets_list_object_types | GET | /jsm/assets/workspace/{ws}/v1/objectschema/{id}/objecttypes/flat |
| assets_list_object_type_attributes | GET | /jsm/assets/workspace/{ws}/v1/objecttype/{id}/attributes |

AQL query examples:
- `objectType = Laptop AND Owner.emailAddress = "user@halostudios.com"`
- `objectSchema = "Halo Studios Employees" AND Name LIKE "Nguyen"`
- `Key = "HSE-42"`

`max_results` is hard-capped at 200 per call.

`assets_aql_search(compact=True)` strips each row down to `{id, objectKey, label, objectType:{id,name}}` and forces `includeAttributes=false`, shrinking responses ~100×. Use it for list/browse queries to avoid tool-output truncation; switch to `compact=False` (default) when you need attribute values.

### Assets write surface (opt-in, default OFF)
Disabled unless BOTH env vars are set on the server process:
- `HALO_MCP_ASSETS_WRITE=1`
- `HALO_MCP_ASSETS_WRITE_OBJECT_TYPES=<comma-separated numeric objectType ids>`

If either is missing/empty, the four write tools below do not register.

| Tool | Method | Path |
|---|---|---|
| assets_create_object | POST | /jsm/assets/workspace/{ws}/v1/object/create |
| assets_update_object | PUT | /jsm/assets/workspace/{ws}/v1/object/{id} |
| assets_delete_object | DELETE | /jsm/assets/workspace/{ws}/v1/object/{id} |

Guards:
- Create rejects any `object_type_id` not in the allowlist.
- Update fetches the live object first, reads `objectType.id`, and rejects if not in the allowlist.
- Delete additionally requires `confirm_object_key` to equal the live `objectKey` (e.g. `AMT-10977`). Mismatch raises `AssetsWriteDenied` and no DELETE is sent.
- `attributes` is a friendly dict `{attribute_id: value | [values]}`; the server formats it into Atlassian's verbose `objectAttributeValues` shape.
- Use `assets_list_object_type_attributes` to discover the numeric attribute ids (and their human names) for an object type before writing.
