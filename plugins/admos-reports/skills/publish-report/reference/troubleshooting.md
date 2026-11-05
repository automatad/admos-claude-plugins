# Troubleshooting `publish-report`

Codes come from sections 3, 4 and 8 of the ADMOS reports contract (internal). Find the symptom, apply
the fix, and only repeat a step if the fix says so.

## Upload (`curl` to the ingest Worker)

`curl --fail-with-body` exits with code 22 on an HTTP error and prints the JSON
body `{"error": "<code>"}`. The status in brackets is the HTTP status.

| `error` (status) | What it means | What to do |
|---|---|---|
| `invalid_pass` (401) | The pass is expired (it lives about 10 minutes), was already used, was altered, or the URL's report id / version does not match the pass. | Passes are single-use and not renewable. Call `publish_report` again with the same `report_id`: that creates the next version with a fresh pass and URL. Upload immediately, copying URL and pass unchanged. |
| `length_required` (411) | No `Content-Length`: the body was piped or chunked. | Upload a regular file with `-T <file>`; never `-T -` or a pipe. |
| `too_large` (413) | Larger than the smaller of the pass limit (`upload.max_bytes`) and the Worker's hard cap. | `check-report.sh --max-bytes <upload.max_bytes> <file>`; shrink (no source maps, compress images, trim embedded data), then publish a new version. |
| `unsupported_type` (415) | `Content-Type` is not `text/html`. | Send exactly `-H "Content-Type: text/html; charset=utf-8"`. |
| `empty` (422) | Zero bytes or only whitespace. | The build produced nothing; check the build output path. |
| `not_utf8` (422) | Invalid UTF-8. | Re-export as UTF-8 (`<meta charset="utf-8">`); remove binary data pasted into the HTML (use base64 `data:` URLs). |
| `binary_content` (422) | Contains NUL bytes. | Same: binary data must be base64 inside a `data:` URL. |
| `disguised` (422) | Starts with a binary signature (PDF, ZIP, PNG, ...) or the first real content is not `<!doctype html` / `<html`. | Upload the HTML file, not an archive or PDF. Put `<!doctype html>` first (BOM, whitespace and comments before it are fine). |
| `version_exists` (409) | This version already has an upload. The first attempt may have worked and the reply was lost. | `get_report_status`: if the latest version is `uploaded` with the sha256 you expect, continue to step 5. Otherwise `publish_report` with `report_id` for a new version. |
| `https_required` (400) | The URL started with `http://`. | Use `upload.url` from the `publish_report` response exactly (it is `https://`). The pass went over the network unencrypted: publish a new version for a fresh pass. |
| `rate_limited` (429) | Too many attempts. | Wait a minute. If you still need to retry, get a new version (the pass may be spent). |
| 404 (no JSON or `not_found`) | The URL is wrong (report id must be 22 URL-safe characters, version a whole number) or you hit the wrong host. | Use `upload.url` from the `publish_report` response exactly. |
| `curl: (6)` / `(7)` / `(28)` | Cannot resolve, connect or time out. | Check network or VPN, retry the same command while the pass is still valid (under 10 minutes); if it expired, publish a new version. |
| 201 vs 202 | 201 `uploaded`: ADMOS confirmed. 202 `uploaded_pending_confirmation`: stored, ADMOS confirmation is queued and retried for up to 24 h. | On 202, poll `get_report_status` every minute or so; approve only when the latest version's status is `uploaded`. |

The 4xx upload errors never leave a partial file behind: the Worker removes it.

## MCP tools

| Symptom | What it means | What to do |
|---|---|---|
| Tool not found (`publish_report` missing; `mcp__admos__publish_report` in Claude Code) | The server is not connected, not named `admos`, or the account is not staff. | Connect and sign in to the `admos` server: Claude Code `/mcp` -> `admos` -> Authenticate (or `claude mcp login admos`); Cursor Settings -> MCP -> `admos` -> Connect; Codex `codex mcp login admos`. Check the client lists a server called `admos`. Ask your admin for the ADMOS MCP URL or the managed setup if it is missing. |
| "reconnect with OAuth" / "OAuth required" | The call came with a dashboard token or personal API token. Report tools accept OAuth only. | Sign in to the `admos` server again with the client's MCP sign-in (the browser flow). Do not paste tokens. |
| `insufficient_scope` / 403 about `reports:*` | The OAuth token lacks the scope the tool needs (`reports:draft` for `publish_report`, `reports:read` for `get_report_status`, `reports:publish` for `approve_report` and `revoke_report`). | Sign out of the `admos` server in the client and sign in again, so a new token with the right scopes is issued. If it persists, an administrator must check the OAuth scopes configured for the `admos` server. |
| Permission denied: needs staff or `reports.approve_report` | The user is not staff, or may draft but not approve or revoke. | Ask an ADMOS admin to add the user to the `report-approvers` group (approve and revoke only). Drafting does not need it. |
| `publish_report`: site does not belong to publisher; unknown publisher or site; `report_id` not found; publisher/site mismatch for a new version | Wrong ids, or a new version was requested for different parties than the report has. | Redo the lookup (step 2) and confirm names again. A new version must use the report's own publisher and site. |
| `publish_report`: expiry out of range | `expires_in_days` above 365 or below 1. | Use 1 to 365. |
| `approve_report`: not the latest version / version not `uploaded` | A newer version was created, or the upload has not been confirmed (202). | `get_report_status`; approve the version it names as latest, once its status is `uploaded`. |
| `approve_report`: sha256 mismatch | The digest you passed is not the uploaded one (for example a stale value). | Copy the sha256 from `get_report_status`, show it, get a new yes. |
| `approve_report`: names do not match | `publisher_name` / `site_name` differ from the report's (trimmed, case-insensitive). | Use the names exactly as `get_report_status` returns them. |
| `approve_report`: missing acknowledgements | `acknowledged_warnings` lacks codes from `required_acknowledgements`. | Show the full list to the operator and send exactly that list. |
| `approve_report`: revoked or expired report | The report cannot be published. | Create a new report with `publish_report` (no `report_id`). |
| `approve_report` / `revoke_report`: the host call failed, "report stays in its previous state" | The ingest Worker was unreachable or refused the instruction. Nothing changed. | Retry later; if it persists tell an administrator (the ADMOS report events log has `publish_failed` / `revoke_failed`). |
| The confirmation prompt for `approve_report` never appears and the call is denied | The client runs without prompting (Claude Code `dontAsk` or `-p`, Codex `--ask-for-approval never`, Cursor non-interactive) while policy requires a prompt. | Run interactively with prompts on. |
| `approve_report` ran without any confirmation prompt | The client auto-approves MCP tools (for example Cursor Auto-review or an allowlist entry, or Codex `approval_mode = "approve"`). | Configure the client to always ask for `approve_report` and `revoke_report` (plugin README, "Confirm approvals"). |

## Bundling

| Symptom | Fix |
|---|---|
| `check-report.sh` lists external hosts | Find the `<script src>`, `<link href>`, `@import` or `url(...)` that names the host and bundle or inline it. Common: Google Fonts, CDN chart libraries, remote images. |
| Blank page in the preview | Open the browser console on the preview link. Usual causes: a `fetch()` of data (embed it instead), `localStorage` access throwing in the sandbox (guard it or drop it), or an absolute asset path (`/assets/...`) left in the HTML (assets were not inlined: rebuild with the single-file config). |
| `npm install --no-save` removed other packages | It re-syncs `node_modules`. Run `npm ci` to restore. |
| `vite build` fails to resolve the plugin | The `--no-save` install was pruned by another `npm install`; run it again. |
| `git status` shows `vite.report.config.ts` or `dist-report/` | Delete them, or add them to `$(git rev-parse --git-path info/exclude)`. They must never be committed. |
