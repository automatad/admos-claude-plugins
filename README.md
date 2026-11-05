# ADMOS agent plugins

A plugin marketplace (`admos-tools`) for ADMOS operations. It works in Claude Code, Cursor and
Codex, and the skill inside works in any agent that reads [Agent Skills](https://agentskills.io)
(`SKILL.md`).

| Plugin | What it does |
|---|---|
| `admos-reports` | Publishes an HTML report (dashboard, analysis, deck-like page) to the ADMOS reports host so a publisher's users can open it. It bundles the report into one self-contained HTML file, confirms the publisher and site by name, uploads the file and shows its size, hash and warnings. Only after the operator says yes does it approve the report and return a share link. |

These plugins only work with an **ADMOS staff account**. Without one, they can do nothing.

The repository is public only so staff can install without a GitHub login. It is **not open
source**: only Automatad Inc. employees and contractors may use it, for Automatad work (see
[LICENSE](LICENSE)).

## What every client needs

1. **The plugin or the skill** (per client, below).
2. **The ADMOS MCP server**, registered under the name `admos`, signed in with your ADMOS staff
   account. Your admin gives you its URL (written `<ADMOS MCP URL>` below) or sets it up for you.
3. **A shell the agent may use, with git, Node/npm and curl.** The report file goes from your
   machine straight to the reports host; it never passes through the chat or through ADMOS.
4. **Confirmation before approving.** Set the client to always ask before `approve_report` and
   `revoke_report` (see [Confirm approvals](#confirm-approvals)). The skill also asks you for an
   explicit yes in the conversation first.

## Claude Code

```
/plugin marketplace add automatad/admos-claude-plugins
/plugin install admos-reports@admos-tools
```

Restart Claude Code. The skill appears as `/admos-reports:publish-report`. If `admos` is not
already set up by managed settings:

```sh
claude mcp add --transport http admos <ADMOS MCP URL>
```

Then go to `/mcp` > `admos` > **Authenticate**. If `admos` was connected before reports were
enabled, clear the sign-in and authenticate again to get the reports scopes.

## Cursor

Install the plugin: **Customize** > **Plugins** > **From GitHub Repository** >
`automatad/admos-claude-plugins`, then install `admos-reports`. Alternatively copy
`plugins/admos-reports/skills/publish-report/` into `~/.cursor/skills/` (or `~/.agents/skills/`).

Add the server to `~/.cursor/mcp.json` and click **Connect** in Settings > MCP:

```json
{ "mcpServers": { "admos": { "url": "<ADMOS MCP URL>" } } }
```

Cursor sign-in requires an ADMOS version with Cursor sign-in support. Ask your admin if the
connection fails with a redirect URI error.

## Codex

```sh
codex mcp add admos --url <ADMOS MCP URL>
codex mcp login admos
codex plugin marketplace add automatad/admos-claude-plugins
codex plugin add admos-reports@admos-tools
```

You can also install `admos-reports` from the plugin browser (`/plugins` in Codex CLI, or
Plugins in the Codex app). Alternatively copy
`plugins/admos-reports/skills/publish-report/` into `~/.agents/skills/`.

## Any other MCP client

1. Add the ADMOS MCP server as a remote (streamable HTTP) server named `admos` with OAuth, and
   sign in with your ADMOS staff account.
2. Copy `plugins/admos-reports/skills/publish-report/` into the folder your client loads Agent
   Skills from (often `~/.agents/skills/`). If the client has no skills support, give the agent
   that folder's `SKILL.md` as instructions.

## Use

Ask the agent to "publish this report for <publisher>" in the folder that holds the report, or
invoke the `publish-report` skill directly (`/admos-reports:publish-report` in Claude Code).

## Confirm approvals

`approve_report` makes a report visible to a publisher's users, and `revoke_report` takes it
down. The client must ask you before either call runs:

- **Claude Code:** managed settings put both tools in `permissions.ask` (your admin rolls this
  out). By hand, do not add them to an allow list.
- **Codex:** in `~/.codex/config.toml`:

  ```toml
  [mcp_servers.admos]
  url = "<ADMOS MCP URL>"

  [mcp_servers.admos.tools.approve_report]
  approval_mode = "prompt"

  [mcp_servers.admos.tools.revoke_report]
  approval_mode = "prompt"
  ```

  `codex mcp add` already wrote the first table; add the two tool tables under it.
- **Cursor:** never add `admos:approve_report`, `admos:revoke_report` or `admos:*` to the MCP
  allowlist (Settings or `~/.cursor/permissions.json`). In Auto-review mode Cursor sends tools
  that are not allowlisted to a classifier, which can run them without asking; steer it with:

  ```json
  { "autoRun": { "block_instructions": ["Always ask me before calling approve_report or revoke_report on the admos MCP server."] } }
  ```

  Cursor treats this as guidance, not enforcement. Use the Allowlist run mode if you need the
  prompt every time.
- **Other clients:** turn off auto-approval for these two tools.

## Update

- Claude Code: `/plugin marketplace update admos-tools` (managed settings update automatically).
- Cursor: update the plugin from Customize > Plugins.
- Codex: `codex plugin marketplace upgrade admos-tools`.
- Copied skill folders: copy the folder again.

## Releasing a change

1. Edit the plugin under `plugins/<name>/`. Keep the skill text tool-neutral.
2. Bump `version` in all three manifests of the plugin (`.claude-plugin/`, `.cursor-plugin/`,
   `.codex-plugin/`), keeping them equal.
3. Run `claude plugin validate .`.
4. Merge to `main`. Every push to `main` reaches every user's machine on their next update.

## Layout

| Path | What it is |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace `admos-tools` for Claude Code |
| `.cursor-plugin/marketplace.json` | The same marketplace for Cursor |
| `.agents/plugins/marketplace.json` | The same marketplace for Codex |
| `plugins/admos-reports/.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json` | The plugin manifest for each client (same name and version) |
| `plugins/admos-reports/skills/publish-report/` | The skill shared by every client: `SKILL.md`, `scripts/check-report.sh`, `reference/troubleshooting.md` |
