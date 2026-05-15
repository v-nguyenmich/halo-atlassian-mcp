---
name: halo-atlassian
description: Interact with the Halo Studios Atlassian tenant (343industries.atlassian.net) — Jira issues, Atlassian Assets (CMDB), and Confluence — using the halo-atlassian MCP server for read paths and direct REST (PowerShell + Basic auth) for write paths the MCP server does not expose. Use this skill any time the user asks to query, create, update, transition, link, or comment on Jira issues, look up assets/licenses/hardware, or read/write Confluence pages on this tenant.
allowed-tools:
  - halo-atlassian-jira_search
  - halo-atlassian-jira_get_issue
  - halo-atlassian-jira_get_transitions
  - halo-atlassian-jira_search_users
  - halo-atlassian-jira_get_user_groups
  - halo-atlassian-jira_add_comment
  - halo-atlassian-jira_transition_issue
  - halo-atlassian-jira_update_issue
  - halo-atlassian-jira_create_issue
  - halo-atlassian-assets_aql_search
  - halo-atlassian-assets_get_object
  - halo-atlassian-assets_get_object_attributes
  - halo-atlassian-assets_list_object_type_attributes
  - halo-atlassian-assets_list_object_types
  - halo-atlassian-assets_list_schemas
  - halo-atlassian-confluence_search
  - halo-atlassian-confluence_get_page
  - halo-atlassian-confluence_get_page_by_title
  - halo-atlassian-confluence_create_page
  - halo-atlassian-confluence_update_page
  - halo-atlassian-confluence_get_attachments
  - halo-atlassian-confluence_upload_attachment
  - powershell
---

# halo-atlassian skill

General-purpose interaction layer for the Halo Studios Atlassian tenant
(`https://343industries.atlassian.net`). Covers Jira, Assets (CMDB), and
Confluence. Uses the `halo-atlassian` MCP server for everything it can do
and falls back to direct REST + Basic auth for the rest.

## Prerequisites

- `halo-atlassian` MCP server configured in `~/.copilot/mcp-config.json`
  under `mcpServers.halo-atlassian`. The MCP server reads its own
  credentials from its env block.
- An Atlassian API token stored in **Windows Credential Manager** (Generic
  Credential), retrievable from PowerShell. Two equivalent options:
  - `Get-Secret -Name AtlassianApiToken -Vault CopilotVault -AsPlainText`
    (PowerShell SecretManagement + SecretStore — recommended)
  - `cmdkey`-stored Generic Credential read via Win32 `CredRead` P/Invoke
- Atlassian email used for Basic auth — defaults to current user's UPN.
  Override with `$env:ATLASSIAN_EMAIL`.

If credentials are missing, stop and tell the user how to add them — do
not prompt for the token in chat.

## Auth header helper

Use this for any direct REST call:

```powershell
$token = Get-Secret -Name AtlassianApiToken -Vault CopilotVault -AsPlainText
$email = if ($env:ATLASSIAN_EMAIL) { $env:ATLASSIAN_EMAIL } else { 'v-nguyenmich@halostudios.com' }
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${email}:${token}"))
$headers = @{ Authorization = "Basic $b64"; 'Content-Type'='application/json'; Accept='application/json' }
$base = 'https://343industries.atlassian.net'
```

## Tool selection rule

For every action: **prefer the MCP tool**, fall back to direct REST only
when the MCP tool is missing or known-broken. Known gaps as of writing:

| Action | MCP tool? | Notes |
|---|---|---|
| JQL search, issue read, comment, simple update | yes | use MCP |
| Workflow transition with required-screen fields | partial | MCP `jira_transition_issue` accepts only `transition_id` + `comment_markdown`; if the screen requires custom fields, POST `/rest/api/3/issue/{key}/transitions` directly |
| Issue links (Duplicate, Blocks, Relates, ...) | **no** | direct POST `/rest/api/3/issueLink` |
| Remote links (Confluence/web) on issues | **no** | direct POST `/rest/api/3/issue/{key}/remotelink` |
| Discover available link types | **no** | `GET /rest/api/3/issueLinkType` |
| Confluence page **read**, attachments | yes | use MCP |
| Confluence page **update** | broken (HTTP 405) | direct PUT `/wiki/api/v2/pages/{id}` |
| Assets read (AQL, get object, list types/attrs) | yes | use MCP |
| Assets write (create/update objects) | not used here | not in scope of this skill |

## Jira

### Identifying users
Always resolve a person to their `accountId` before filtering by
assignee/reporter. Use `halo-atlassian-jira_search_users` with the user's
email; never filter by display name.

### Search (JQL)
- Tool: `halo-atlassian-jira_search`
- Default `max_results` is small. For bulk pulls pass `max_results: 200`+
  and check `isLast` / `nextPageToken`. If a single page returns the cap,
  there are more.
- Useful starter JQL:
  - `assignee = "<accountId>" AND statusCategory != Done ORDER BY updated DESC`
  - `project = <KEY> AND created >= -7d ORDER BY created DESC`
  - `text ~ "<keyword>" AND project = <KEY>`

### Get one issue
- Tool: `halo-atlassian-jira_get_issue`
- Default field list is small. Pass an explicit
  `fields="summary,status,assignee,priority,..."` to keep payload tight.
- Use `fields="*all"` only when you need to discover custom fields — the
  payload is large.

### Discover custom-field IDs
The simplest way to find a custom-field id and its allowed values:
```powershell
Invoke-RestMethod -Uri "$base/rest/api/3/issue/<KEY>/editmeta" -Headers $headers
```
Returns `fields.<customfield_NNNNN>` with `name`, `schema.type`, and
`allowedValues`. Use this every time before sending a value to a custom
field — types vary (string, ADF, array of `{value}`, single `{value}`,
`{name}`, etc.).

### Update fields
- Tool: `halo-atlassian-jira_update_issue` (filtered against an
  allowed-fields list inside the MCP server).
- For fields the MCP tool refuses, PUT `/rest/api/3/issue/{key}` directly.

### Status changes (transitions)
1. `halo-atlassian-jira_get_transitions` → returns transitions available
   from the current state, including each `id` and whether it has a
   screen (`hasScreen: true` means there are extra fields to fill).
2. If the screen has no required fields you don't already have, use
   `halo-atlassian-jira_transition_issue`.
3. If the screen has required custom fields, POST directly:
   ```powershell
   $payload = @{
     transition = @{ id = '<transition_id>' }
     fields = @{
       resolution        = @{ name = "<...>" }
       customfield_NNNNN = <shape from editmeta>
     }
   } | ConvertTo-Json -Depth 12
   Invoke-RestMethod -Method POST -Uri "$base/rest/api/3/issue/<KEY>/transitions" -Headers $headers -Body $payload
   ```
4. If a transition fails with `"Can't move (... permission ... missing
   required information)"` and an empty `errors` object, **stop and
   report**. The likely cause is a workflow condition you can't see
   (assignee check, security level, hidden required field). Don't loop-retry.

### Comments
- `halo-atlassian-jira_add_comment` — markdown body. Visibility default
  matches the issue type (often internal in JSM portals).
- For an explicit **public / user-facing** JSM comment, POST directly:
  ```powershell
  $body = @{
    body = (New-AdfPara 'Hello from IT.')
    properties = @(@{ key='sd.public.comment'; value=@{ internal=$false } })
  } | ConvertTo-Json -Depth 12
  Invoke-RestMethod -Method POST -Uri "$base/rest/api/3/issue/<KEY>/comment" -Headers $headers -Body $body
  ```

### Issue links
- Discover types: `GET /rest/api/3/issueLinkType` (Duplicate, Blocks,
  Relates, Caused by, ...).
- Create:
  ```powershell
  $body = @{
    type = @{ name = 'Duplicate' }
    inwardIssue  = @{ key = '<canonical>' }   # "is duplicated by"
    outwardIssue = @{ key = '<dupe>' }        # "duplicates"
  } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method POST -Uri "$base/rest/api/3/issueLink" -Headers $headers -Body $body
  ```

### Remote / Confluence links on an issue
```powershell
$body = @{
  object = @{
    url   = '<https://...wiki/spaces/.../pages/.../Title>'
    title = '<Title>'
    icon  = @{ url16x16 = "$base/wiki/images/icons/favicon.png"; title='Confluence' }
  }
  relationship = 'mentioned in'
} | ConvertTo-Json -Depth 8
Invoke-RestMethod -Method POST -Uri "$base/rest/api/3/issue/<KEY>/remotelink" -Headers $headers -Body $body
```
For the richer "Confluence pages" panel, add `application = @{ type='com.atlassian.confluence'; name='Confluence' }` and a `globalId = "appId=<id>&pageId=<id>"`. Without a valid `appId` it falls back to a plain web link — same click behavior, different sidebar group.

## ADF (Atlassian Document Format) gotcha

Several fields look like plain strings but require ADF: `description`,
some `Root cause`-style custom fields, all `body` fields on comments.
If a write rejects with `"Operation value must be an Atlassian
Document"`, wrap the text:

```powershell
function New-AdfPara($text) {
  @{ type='doc'; version=1; content=@(@{
    type='paragraph'; content=@(@{ type='text'; text=$text }) }) }
}
```

## Atlassian Assets

### Schemas
List with `halo-atlassian-assets_list_schemas`. Frequently used:
- id `2` — **Asset Management** (hardware, software, licenses)
- id `4` — **Service Catalog**
- id `46` / `82` — **Halo Studios Employees** / **HS-Employees**
- id `116` — **M365/DL Groups**

### Object types
List with `halo-atlassian-assets_list_object_types(schema_id)`. In
schema 2, common types include:
- `7` Software, `47` License Type, `61` Software Category, `45` Software Supplier
- `63` License
- (others for Desktop, Laptop, Monitor, GPU, etc. — discover live)

### Attribute IDs
Discover with `halo-atlassian-assets_list_object_type_attributes(object_type_id)`.
The output is concatenated JSON objects; parse by wrapping with
`'[' + (raw -replace '\}\s*\{', '},{') + ']'` then `ConvertFrom-Json`.

For reference, the **License** object type (id `63`) has these attribute
IDs (subject to drift — verify before relying on them):

| Attribute ID | Name |
|---|---|
| `336` | Key |
| `337` | Name |
| `381` | Status (In Use / Expired / ...) |
| `374` | Assigned To (User) |
| `392` | Team |
| `376` | Software (→ Software) |
| `377` | License Type (→ License Type) |
| `378` | Serial #/Install Key |
| `383` | Expiration Date |
| `375` | PO (→ Purchase) |
| `394` | User Count |
| `538` | Ticket Created |
| `338` | Created |
| `339` | Updated |

### AQL search
Tool: `halo-atlassian-assets_aql_search`. Pass `aql`,
`include_attributes: true`, `max_results` up to 500. Use `compact: true`
when you only need keys/labels for a long list — strips attribute values
and shrinks the response ~100x.

Patterns:
- By owner email: `Owner.emailAddress = "<email>"` or
  `"Assigned To".emailAddress = "<email>"`
- By human key: `Key = "AMT-1234"`
- By software name (license): `objectType = "License" AND Software.Name = "<name>"`
- Multi-value: `Software.Name IN ("Gaea","Altiverb",...)`
- Empty attribute: `objectType = "License" AND "Serial Number" IS EMPTY`
- Date math: `objectType = "License" AND "Expiration Date" < now("30d")`
- Inbound references (which objects point at THIS one):
  `objectType = "Desktop" AND inboundReferences()` — pair with `Key`/filter.

### Reference picker / Label gotcha
Reference attributes only **search by Object Label**. Label is a per-
attribute toggle in the object-type config; multiple labels concatenate
for display. To make Serial Number searchable in a reference picker,
toggle Label ON for Serial Number — but every existing object must have
a non-empty value for that attribute or the toggle is rejected ("you
need to specify at least one value on all objects within the affected
object type"). Backfill or filter (`<attr> IS EMPTY`) before retrying.

### Inbound references
Assets stores references one-directionally but tracks inbound references
automatically. To see "what other objects link to X", use the
**Referenced By** panel in the UI or `inboundReferences()` in AQL — do
**not** create a manual reverse attribute on the target type.

### Parsing AQL results in PowerShell
```powershell
foreach ($o in $j.values) {
  $get = { param($id) ($o.attributes |
    Where-Object { $_.objectTypeAttributeId -eq $id }).objectAttributeValues |
    ForEach-Object { if ($_.displayValue) { $_.displayValue } else { $_.value } } }
  [pscustomobject]@{
    Key      = $o.objectKey
    Name     = (& $get 337) -join '; '
    AssignedTo = (& $get 374) -join '; '
    # ... etc
  }
}
```
`displayValue` is the human-friendly value (resolved name, formatted
date, user display). Use `value` only for raw IDs.

## Confluence

- Read by id: `confluence_get_page` — `body_format` can be `storage`
  (XHTML), `view` (rendered HTML), or `atlas_doc_format` (ADF).
- Title lookup: `confluence_get_page_by_title(space_id, title)`.
- CQL search: `confluence_search` (the v1 search endpoint — the v2 API
  has no equivalent).
- Attachments list: `confluence_get_attachments(page_id)`.
- Upload attachment (new file): `confluence_upload_attachment(page_id, file_path)`.
- Upload **new version** of an existing attachment: direct POST to
  `/wiki/rest/api/content/{pageId}/child/attachment/{attachmentId}/data`
  multipart with `file=@<path>` and `X-Atlassian-Token: no-check`. The
  v2 attachments endpoint and the MCP `upload_attachment` tool both
  refuse to overwrite by filename ("Cannot add a new attachment with
  same file name as an existing attachment"); using the data-update
  endpoint above creates a new version on the same attachment id.
- Update page body: MCP `confluence_update_page` returns 405 — use
  direct PUT:
  ```powershell
  $payload = @{
    id     = '<pageId>'; status = 'current'; title = '<Title>'
    body   = @{ representation = 'storage'; value = $bodyXhtml }
    version = @{ number = <currentVersion + 1>; message = '<note>' }
  } | ConvertTo-Json -Depth 10
  Invoke-RestMethod -Method PUT -Uri "$base/wiki/api/v2/pages/<pageId>" -Headers $headers -Body $payload
  ```
- Storage XHTML for code blocks needs CDATA. To embed `<![CDATA[...]]>`
  in tool-call text safely, use placeholders and replace at write time:
  ```powershell
  $open = '<' + '!' + '[' + 'CDATA' + '['; $close = ']' + ']' + '>'
  $body = $tpl.Replace('[CDATA_OPEN]', $open).Replace('[CDATA_CLOSE]', $close)
  ```
- **AI footer rule:** any Confluence page or document the agent
  authors must end with `<hr/>` then
  `<p><em>This document was created using AI.</em></p>`.

## Cross-domain workflows (Jira ↔ Assets ↔ Confluence)

These are the patterns this skill exists for. Pick whichever matches
the user's ask:

| Goal | Approach |
|---|---|
| "What does <user> own?" | `assets_aql_search` with `Owner.emailAddress = "<email>"` or `"Assigned To".emailAddress = "<email>"`, optionally filter by `objectType` (Laptop, License, ...). |
| "What tickets are assigned to <user>?" | `jira_search_users(email)` → `jira_search` with `assignee = "<accountId>" AND statusCategory != Done`. |
| "What software/hardware does this ticket reference?" | `jira_get_issue(*all)` → look at CMDB customfields (any `customfield_*.cmdb.objectKey` in the `expand` list maps to an Asset key). Then `assets_get_object(<id>)`. |
| "Find/cluster duplicate JSM tickets about the same item" | Pull open tickets in the project, normalize the summary (strip prefix/suffix), group, oldest = canonical, others = duplicates → link via `Duplicate`. |
| "Audit which licenses for software X are expired and who owns them" | `assets_aql_search` for `objectType = "License" AND Software.Name = "X"` with `include_attributes: true`; project `Status`, `Assigned To`, `Expiration Date`. |
| "Comment on the canonical ticket with the affected users" | After Asset lookup, post a `sd.public.comment` listing the user names. |
| "Attach a Confluence runbook to a ticket" | Direct POST `/rest/api/3/issue/{key}/remotelink` (see remote links above). |
| "Update a Confluence runbook from agent" | Build storage XHTML → direct PUT `/wiki/api/v2/pages/{id}` with `version.number = current + 1`. Append AI footer. |
| "Migrate hardware from one user to another" | `assets_aql_search` to find the asset → if MCP write tools aren't available, instruct the user to update via UI; do not invent a write path. |

## General rules

- **Pagination:** any list query (`jira_search`, `assets_aql_search`,
  `confluence_get_attachments`) — default caps are low. For "all" queries
  pass `max_results: 200`+ and check `isLast` / `nextPageToken`.
- **Output size:** large MCP outputs spill to a temp file. Use `view`
  with `view_range`, `grep`, or `ConvertFrom-Json` on the temp path; do
  not dump entire JSON to chat.
- **PowerShell quoting:** wrap multi-statement PowerShell in a single
  here-string `$cmd = @' ... '@` or one-liner with `;` separators when
  running through the powershell tool, to avoid the interactive prompt
  consuming each line.
- **Destructive actions:** transitions to terminal states, deletes, mass
  updates — require explicit user confirmation. If the user has
  pre-approved a batch, still stop and report the first unexpected
  error; don't loop-retry blindly.
- **AccountIds:** resolve at runtime via `jira_search_users(email)`; do
  not hardcode. AccountIds are tenant-stable but personal — keep them
  out of shared files.

---

This document was created using AI.
