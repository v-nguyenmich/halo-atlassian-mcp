# Copilot CLI skills for halo-atlassian

Optional client-side skills that pair with this MCP server. The CLI loads
skills from `~/.copilot/skills/<name>/SKILL.md`, so installation is a copy
or a symlink.

## Available skills

- **halo-atlassian** — General Jira / Atlassian Assets / Confluence
  interaction patterns. Documents which actions to do via MCP tools and
  which require direct REST (issue links, remote links, Confluence page
  update, transitions with required-screen fields), plus AQL recipes for
  the Asset CMDB and an ADF-wrapping helper.

## Install

PowerShell (Windows):

```powershell
$src = "<path-to-clone>\skills\halo-atlassian"
$dst = "$HOME\.copilot\skills\halo-atlassian"
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null

# Option A: copy (simple, no admin needed)
Copy-Item -Recurse -Force $src $dst

# Option B: symlink (auto-updates with `git pull`; needs admin OR Dev Mode)
New-Item -ItemType SymbolicLink -Path $dst -Target $src
```

bash (macOS / Linux / WSL):

```bash
ln -s "$(pwd)/skills/halo-atlassian" "$HOME/.copilot/skills/halo-atlassian"
```

Then in the CLI run `/skills` and toggle `halo-atlassian` on. It loads on
the next session start.

## Prerequisites

The skill assumes:

1. The `halo-atlassian` MCP server (this repo) is configured in
   `~/.copilot/mcp-config.json` under `mcpServers.halo-atlassian`.
2. An Atlassian API token is reachable from PowerShell — either via
   `Get-Secret -Name AtlassianApiToken -Vault CopilotVault` (recommended)
   or a `cmdkey`-stored Generic Credential read with the Win32 `CredRead`
   API. The skill will not prompt for the token in chat.
3. `$env:ATLASSIAN_EMAIL` set to the Atlassian login email (or update the
   default in the skill).
