---
name: publish-report
description: Publish an HTML report (dashboard, analysis, deck-like page) to the ADMOS reports host so a publisher can view it. Bundles it into one self-contained HTML file, confirms publisher and site by name, uploads it, shows size/hash/warnings, and only after the operator's explicit yes approves it and returns a share link. Use when the user says "host it", "publish this report", "share this with the publisher", "put this online for <publisher>", "send them a link to this report", or asks to revoke or re-publish a hosted report.
when_to_use: The user has built or pointed at an HTML or Vite/React report and wants a link for a publisher or site. Also when they ask for the status, a new version or the revocation of a report that was already hosted.
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/check-report.sh *)
---

# Publish a report to ADMOS

You take a report from "built locally" to "a publisher's users can open it", in
four stages: **bundle -> confirm who it is for -> upload and inspect -> approve
and share**. Interfaces: sections 3 and 8 of the ADMOS reports contract
(internal). Problems at any stage: `reference/troubleshooting.md`
next to this file.

## Rules that never bend

1. **Never read the built report into the conversation.** No `cat`, `head`,
   `sed`, `grep` that prints lines, and no Read tool on the built file. Inspect it
   only with `${CLAUDE_SKILL_DIR}/scripts/check-report.sh` (prints counts and
   hostnames only), or if that helper misbehaves with `wc -c <file` and
   `shasum -a 256 <file` (size and digest only). The file can hold publisher data
   the conversation must not see.
2. **Report content never goes into an MCP call.** `publish_report` takes
   metadata only (ids, title, expiry).
3. **Ids come from a lookup, never from memory or guesses.** Publisher and site
   ids must come from the ADMOS tools in step 2, and the operator must have said
   yes to those exact names.
4. **No approve or revoke without an explicit "yes" in this conversation** for
   the exact values you are about to send. "Looks good" about the report is not
   approval to publish; ask the approval question in step 5 and wait.
5. **The upload pass is a secret.** Never print it, repeat it in prose, or use
   `curl -v`, `--trace` or `-i`. It appears once in the tool result and once in
   the upload command, and it is single-use.
6. **If a tool is missing or says "reconnect with OAuth", stop** and tell the
   operator what to do (below). Do not fall back to a dashboard token, a personal
   API token, direct HTTP calls to ADMOS, or a different upload route.

Tool names assume the ADMOS MCP server is registered as `admos`:
`mcp__admos__publish_report`, `mcp__admos__get_report_status`,
`mcp__admos__approve_report`, `mcp__admos__revoke_report`, plus the lookup tools
`mcp__admos__search_platform`, `mcp__admos__manage_domains`,
`mcp__admos__get_domain_details`. If these are not available (different server
name, not connected, not staff), stop. Connecting: `/mcp` -> `admos` ->
Authenticate (or `claude mcp login admos` in a shell), signed in as an ADMOS
staff user.

## Step 1 - Bundle into ONE self-contained HTML file

The viewer shows the file in a sandboxed iframe with a strict policy: no network
(`connect-src 'none'`), images and media only from `data:`/`blob:`, fonts only
from `data:`, no CDN scripts, no cookies or `localStorage` (opaque origin), no
forms, no navigation. So everything must be inside the one file: CSS, JS, images,
fonts, chart libraries and the data itself (embed the numbers at build time; do
not `fetch()` them).

Find what the report is:

- **Vite project** (a `vite.config.*` and `vite` in `package.json`): use
  `vite-plugin-singlefile`, added **temporarily and never committed** (below).
- **Plain HTML**: inline it by hand (below).
- **Next.js, CRA, webpack or anything else**: do not bolt a plugin on. Ask the
  operator whether to port the report to a small Vite app or export a static page.

### Vite / React

Add the plugin without touching `package.json` or the lockfile, with a throwaway
config that you remove afterwards:

```bash
npm install --no-save vite-plugin-singlefile          # node_modules only
printf '%s\n' 'vite.report.config.ts' 'dist-report/' >> "$(git rev-parse --git-path info/exclude)"   # keep both out of commits
```

Create `vite.report.config.ts` next to the real config. Copy the plugins the real
config uses (`react()` below is the usual one):

```ts
// vite.report.config.ts - temporary, do not commit.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: {
    outDir: "dist-report",
    emptyOutDir: true,
    assetsInlineLimit: 100_000_000, // inline every asset as a data: URL
    cssCodeSplit: false,            // one <style>, not separate .css files
    sourcemap: false,
  },
});
```

(The plugin already sets `assetsInlineLimit`, `cssCodeSplit: false` and a single
chunk by default; stating them keeps the intent visible. Works with Vite 5.4 to 8.
Source: https://github.com/richardtallent/vite-plugin-singlefile.)

Build and clean up:

```bash
npx vite build -c vite.report.config.ts          # -> dist-report/index.html
rm vite.report.config.ts
git status --short                                # nothing of ours should be listed
```

If the real config is an async function or has `define`/`resolve.alias` the
report needs, mirror those in the report config instead of dropping them.

Source rules so the bundle stays self-contained:

- **Chart libraries:** `import` them from npm (`chart.js`, `echarts`, `d3`, ...)
  so they are bundled. Never `<script src="https://cdn...">` or dynamic
  `import("https://...")`.
- **Fonts:** system font stack, or import from `@fontsource/*` (woff2 is inlined
  as `data:`). No Google Fonts `<link>` and no `@import url(https://...)`.
- **Images:** `import logo from "./logo.png"` (inlined) or `data:` URLs. No remote
  `<img src>`; no `fetch()` of JSON at runtime.
- **Routing:** none, or hash-based. There is no server behind the page.
- **Storage:** do not rely on `localStorage`, `sessionStorage`, cookies or
  IndexedDB; they throw in the sandbox. Keep state in memory.

### Plain HTML

Make one `.html` file. Put CSS in `<style>` and JS in `<script>`. Embed images
and fonts as `data:` URLs, appended by the shell, never echoed:

```bash
{ printf 'data:image/png;base64,'; base64 < logo.png | tr -d '\n'; } > logo.dataurl
```

For a library, bundle it into an inline script rather than linking a CDN
(`npx esbuild entry.js --bundle --minify --format=iife --outfile=bundle.js`, then
paste the bundle into a `<script>`). The file must begin with `<!doctype html>`
or `<html` (a BOM, whitespace and comments before it are fine).

### Verify the bundle

```bash
${CLAUDE_SKILL_DIR}/scripts/check-report.sh dist-report/index.html
```

It prints size, sha256, whether the server would reject the file, and the
**hostnames** of external resources. Aim for `external_references: 0`. The
server's default limit is 10 MiB (the real per-upload limit arrives with the
pass; re-check against it with `--max-bytes`). If it is too large: drop source
maps, compress images, reduce embedded data, avoid bundling two copies of a
library. Report to the operator: file path, size, sha256, and any external
hosts. Remember the sha256: it must match what the server reports later.

## Step 2 - Confirm publisher and site, by name

Never create a draft before the operator has confirmed who it is for.

1. Take the publisher and site names the operator gave. If they gave none, ask.
2. Look them up with the ADMOS tools (they return ids; you must use those):
   - `mcp__admos__search_platform` with `query: "<name>"`,
     `entity_types: ["publisher", "domain"]`, `limit: 10`.
   - `mcp__admos__manage_domains` with `action: "list"` and `publisher_id` to list
     the publisher's sites; `mcp__admos__get_domain_details` with `domain_id` to
     inspect one site.
3. If there are several candidates or names that look alike (for example
   "Acme Media" and "Acme Media Group"), list them all and ask which one. Do not
   pick one yourself.
4. Show exactly this and ask for an explicit yes:

   > **Publisher: Acme Media (uid `pub_1a2b`, id 42) · Site: acme.com (id 77)**
   > Title: "Floors review, Q3" · Visible to users of Acme Media until <date>
   > (90 days by default, up to 365).
   > Is this the right publisher and site? (yes / no)

   Use the uid your lookup returned. If a lookup does not return one, show the id.
   Ask for the title (no personal or customer data in it) and the expiry if the
   operator has not said. Wait for "yes".

## Step 3 - Create the draft and upload

1. Call `mcp__admos__publish_report` with `publisher_id`, `site_id`, `title`,
   `expires_in_days` (omit for 90). To add a new version of a report you already
   created, also pass `report_id` (publisher and site must match). No field takes
   file content.
2. Check the response before uploading:
   - `publisher.name` and `site.name` equal what the operator confirmed. If not,
     stop and say so; do not upload.
   - `status` is `awaiting_upload`; note `report_id`, `version`, `share_link`,
     `preview_link`.
   - `upload.max_bytes` is at least the file size; if not, run
     `check-report.sh --max-bytes <upload.max_bytes>` and shrink the file.
   - The pass expires at `upload.pass_expires_at` (about 10 minutes). Upload now.
3. Upload with exactly this shape (the contract's reference command). Put the pass
   and URL in shell variables inside the one command; they live only for that
   command because each Bash call is a fresh shell:

   ```bash
   PASS='<upload.pass>'; UPLOAD_URL='<upload.url>'
   curl --fail-with-body -sS -T dist-report/index.html \
     -H "Authorization: Pass $PASS" -H "Content-Type: text/html; charset=utf-8" \
     "$UPLOAD_URL"
   ```

   Claude Code will ask permission to run this command (it is deliberately not
   pre-approved); the operator sees the upload URL there.

   `-T <file>` streams a regular file with a Content-Length; do not pipe the file
   or use `-T -` (chunked uploads get 411). On failure curl exits 22 and prints the
   JSON error body; the `error` code tells you what happened (see
   `reference/troubleshooting.md`). Do not retry a rejected pass; get a new
   version with `publish_report` and `report_id`.
4. Parse the JSON response:
   `{status, rid, ver, sha256, size, warnings: [...], name_matches: [...]}`.
   - `status: "uploaded"` (HTTP 201): ADMOS confirmed the arrival.
   - `status: "uploaded_pending_confirmation"` (HTTP 202): the bytes are stored
     but ADMOS was unreachable; the Worker retries for up to 24 hours. Poll
     `get_report_status` until the latest version is `uploaded` before approving.
   - `sha256` and `size` must equal what `check-report.sh` printed. If they differ,
     stop: something altered the bytes.

## Step 4 - Report back to the operator

Present, in this order:

1. **Size and hash:** `<size> bytes · sha256 <first 12 hex>...` (full hash on request).
2. **Other-publisher name matches (high priority).** If `name_matches` is not empty,
   lead with it: the report text mentions the name of a *different* publisher or
   site, which is the typical sign of data from another customer leaking into this
   report. For each match show the matched term (a publisher or site name), the
   count and the publisher id. Ask whether each mention is intended
   (for example a benchmark the publisher is allowed to see). If not, fix the
   report and re-publish. Each one must be acknowledged at approval.
3. **Warnings, grouped, in plain language.** The server never rejects for these;
   they flag things a reviewer should know:

   | Code | What it means | How to fix |
   |---|---|---|
   | `external_resource` | The file loads something from another host (`samples` lists hostnames). The viewer blocks it, so the page will have missing images, fonts or scripts. | Inline it (data: URL, bundled library). |
   | `network_api` | Uses `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon`, workers... The viewer allows no network, so these calls fail. | Embed the data at build time; remove the calls. |
   | `navigation` | Redirects or navigates (`meta refresh`, `<base>`, `window.open`, `location =`). Blocked by the sandbox. | Use in-page navigation. |
   | `form` | Contains a `<form>`. Submitting is blocked. | Remove, or use buttons with in-page handlers. |
   | `embedded_frame` | `<iframe>`, `<object>` or `<embed>`; nothing external can load in them. | Inline the content. |
   | `storage_or_cookie` | Touches cookies, `localStorage`, `sessionStorage` or IndexedDB; these throw in the sandbox. | Keep state in memory. |
   | `dynamic_code` | `eval` or `new Function`; allowed by the viewer but worth a look (often a library). | Fine if from a known library. |
   | `missing_html_end` | No `</html>`; the file may be truncated. | Re-export the full file. |
   | `other_publisher_name:<id>` | See point 2. | Remove the mention or confirm it is intended. |

   Say which ones look harmless for this report (for example `dynamic_code` from a
   chart library) and which are real problems.
4. **Preview link** (`preview_link`): staff-only, signed in with the ADMOS account,
   shows the draft exactly as publishers would see it under the sandbox. Suggest
   opening it before approving. Publishers cannot see drafts.
5. If a warning is fixable, offer to fix it, rebuild, and publish a **new version**
   (`publish_report` with `report_id`, same publisher and site). The new version
   supersedes the unpublished one; repeat from step 3.

## Step 5 - Approve and share (only on an explicit yes)

1. Call `mcp__admos__get_report_status` with `report_id`. Show: publisher name,
   site name, title, latest version and its status (`uploaded`), sha256, size,
   `required_acknowledgements`, current `published_version` (if any) and
   `expires_at`.
2. Ask, and wait for the answer:

   > Approve version 2 of "Floors review, Q3" for **Acme Media** (acme.com)?
   > Everyone with an Acme Media account (and ADMOS staff) will be able to open it
   > at the share link until 2027-01-30. Warnings you are acknowledging:
   > `external_resource`, `dynamic_code`. (yes / no)

3. Only on a clear "yes", tell them what happens next, then call
   `mcp__admos__approve_report` with `report_id`, `version`, `sha256`,
   `publisher_name`, `site_name` and `acknowledged_warnings`, all **exactly as
   shown to the operator**: `acknowledged_warnings` is the list from
   `required_acknowledgements`, no more and no fewer.

   Tell them first: "Claude Code will now show a permission prompt for
   `approve_report`. Your organisation requires it for this tool, so it cannot be
   switched to 'always allow'. Check that the publisher and site names and the
   sha256 in the prompt match what I showed you, then accept. Declining cancels
   the publish." If they decline, stop; do not retry.
4. On success the result is `{status: "published", share_link, version, expires_at}`.
   Show the share link and the expiry. Say that the link can be sent to users of
   that publisher; they sign in with their own ADMOS account (no separate login,
   and the link shows nothing without it). Staff can open it too. Anyone else gets
   a sign-in and then a generic "not found".
5. If `approve_report` errors (stale version, sha mismatch, missing
   acknowledgement, "you need the approver permission"), read
   `reference/troubleshooting.md`. If the approver permission is missing, tell the
   operator to ask an ADMOS admin to add them to the `report-approvers` group.

## Step 6 - Revoking (only when asked)

Only when the operator explicitly asks to take a report down. Ask for a short
reason, confirm which report and publisher ("Revoke 'Floors review, Q3' for Acme
Media? The link stops working immediately and the stored files are deleted; to
bring it back you must upload again. yes / no"), then call
`mcp__admos__revoke_report` with `report_id` and `reason`. A permission prompt
appears here too. To check what is live, `get_report_status`.

## Re-publishing and status

- Changed the report: rebuild (step 1), then `publish_report` with `report_id` for
  a new version, upload, report back, approve. The old published version stays live
  until the new one is approved.
- "Is it live?": `get_report_status` with `report_id` and show status,
  `published_version`, `expires_at` and the share link.
