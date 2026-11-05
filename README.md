# ADMOS Claude Code plugins

A Claude Code plugin marketplace (`admos-tools`) for ADMOS operations.

| Plugin | What it does |
|---|---|
| `admos-reports` | Publishes an HTML report (dashboard, analysis, deck-like page) to the ADMOS reports host so a publisher's users can open it. It bundles the report into one self-contained HTML file, confirms the publisher and site by name, uploads the file and shows its size, hash and warnings. Only after the operator says yes does it approve the report and return a share link. |

These plugins only work with an **ADMOS staff account**. Without one, they can do nothing.

## Install

You need Claude Code, git, Node/npm and curl.

```
/plugin marketplace add automatad/admos-claude-plugins
/plugin install admos-reports@admos-tools
```

The same from a terminal:

```sh
claude plugin marketplace add automatad/admos-claude-plugins
claude plugin install admos-reports@admos-tools
```

Restart Claude Code afterwards. The skill appears as `/admos-reports:publish-report`.

## Connect ADMOS

The plugin uses the ADMOS MCP server, which must be registered under the name `admos`.
Your admin can set this up for everyone with managed settings, or gives you the URL so
you can add it yourself:

```sh
claude mcp add --transport http admos <ADMOS MCP URL>
```

Then go to `/mcp` > `admos` > **Authenticate** and sign in with your ADMOS staff account. If
`admos` was connected before reports were enabled, clear the sign-in and authenticate again
to get the reports scopes.

## Use

Ask Claude to "publish this report for <publisher>", or run `/admos-reports:publish-report`
in the folder that holds the report. Claude Code always asks you before it approves or
revokes a report.

## Update

Run `/plugin marketplace update admos-tools`. Marketplaces added through managed
settings update automatically.

## Releasing a change

1. Edit the plugin under `plugins/<name>/`.
2. Bump `version` in `plugins/<name>/.claude-plugin/plugin.json`.
3. Run `claude plugin validate .`.
4. Merge to `main`. Every push to `main` reaches every user's machine on their next update.

## Layout

| Path | What it is |
|---|---|
| `.claude-plugin/marketplace.json` | The marketplace `admos-tools` and its plugin list |
| `plugins/admos-reports/` | The `admos-reports` plugin: skill `publish-report`, its check script and troubleshooting notes |
