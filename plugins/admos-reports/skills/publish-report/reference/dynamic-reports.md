# Dynamic reports

A dynamic report re-renders itself on a schedule from fresh data and publishes each new
version on its own. You write **render code** (Python) and **data specs**; ADMOS fetches
the data, runs the code in an offline sandbox, uploads the HTML and, once a person has
approved the first version, publishes later versions automatically.

Use this flow only when every number in the report comes from:

- **ADMOS analytics**: the aggregate tables, or raw bid events in the Iceberg archive
  when the aggregates can't answer the question, or
- **the publisher's own Ad Manager network**.

Anything else (numbers pasted in, spreadsheets, other systems, hand-written analysis)
stays a static report: the main flow in `SKILL.md`.

All the rules in `SKILL.md` still apply. In particular: ids come from a lookup, nothing
is approved without an explicit yes, and you never read report output into the
conversation. Two more:

- **You never see the data.** The render code is written against the column names in
  the specs and tested on made-up rows. Real rows reach only the sandbox.
- **Specs never name a publisher or site.** ADMOS adds the report's own site to every
  query, and a spec cannot reach another one.

## 1. Build the data specs

Do this for each dataset the report needs (at most 8):

1. **Analytics question.** Call `check_report_query` with an intent:

   ```json
   {"id": "revenue_by_day", "metrics": ["revenue", "impressions"], "dimensions": ["day"],
    "filters": [], "window": {"unit": "days", "count": 7}}
   ```

   Use the aggregate catalog names (revenue, impressions, ecpm, fill_rate, day, hour,
   country, device, bidder, ad_unit ...). The answer says where the query runs:
   - `target: "clickhouse_aggregate"`: use the returned `spec` as it is. It carries the
     canonical names, and rows use them as keys (`revenue` becomes `sum_revenue`,
     `impressions` becomes `total_impressions`).
   - `code: "needs_raw_form"`: the aggregates don't cover a name or the window, and
     `missing` says which. Send the same intent again with `raw`, the question as an
     Iceberg spec, and use the returned spec:

     ```json
     {"source": "iceberg", "id": "revenue_by_day", "event_types": ["bidWon"],
      "measures": [{"fn": "sum", "column": "cpm", "alias": "revenue"}],
      "dimensions": ["countryName"], "window": {"unit": "days", "count": 30}}
     ```

     Visitor and request identifiers (`ip`, `ua`, `userID`, `sessionId`, `pageViewID`,
     `auctionID`, `uuid`, `referrerURL`) are never allowed. `countryName` holds ISO
     codes (US, CA).
   - Never assume a raw column equals an aggregate metric. The aggregates come from a
     loader with its own logic. When a raw number stands in for one, say so in the
     report.
2. **Ad Manager question.** Write the spec directly. Whole days only, from the site's
   own network, always filtered to the site's ad units:

   ```json
   {"id": "gam_by_day", "source": "gam", "dimensions": ["DATE"],
    "columns": ["TOTAL_LINE_ITEM_LEVEL_IMPRESSIONS", "TOTAL_LINE_ITEM_LEVEL_CPM_AND_CPC_REVENUE"],
    "window": {"unit": "days", "count": 7}}
   ```

Windows are relative to each run, for example "the last 7 days". Aggregates keep 120
days and cover the whole window: daily rollups plus the recent hourly rows. Grouping or
filtering by `hour` works only within 15 days; beyond that `check_report_query` sends the
question to Iceberg. Ad Manager windows are complete days in the network's own time zone.
A dynamic report's expiry is fixed when it is created and is never extended.

## 2. Write the render code

The code runs offline in the sandbox, with pandas, NumPy, SciPy and matplotlib
available. It has up to 30 minutes.

- It reads `/inputs/input_1.json`:

  ```json
  {"report": {"report_id": "...", "title": "...", "publisher": "...", "site": "...",
              "generated_at": "2026-11-25T06:00:00Z"},
   "data": {"<spec id>": {"rows": [{...}, ...],
                          "meta": {"source": "...", "row_count": 7, "truncated": false,
                                   "start": "...", "end": "...", "grain": "day"}}}}
  ```

- It writes exactly one file, `/workspace/report.html`. The viewer rules from step 1
  of `SKILL.md` apply: one self-contained file, charts embedded as `data:` PNG or SVG
  (matplotlib to `BytesIO` to base64), no CDN, fonts or `fetch`.
- Read column names from the rows; don't hard-code them where you can avoid it.
- Handle zero rows: say "no data for this period" rather than failing.
- Escape every value you put into HTML (`html.escape`).
- **Test it locally first**, on made-up rows that use the spec's names. Write a fake
  `input_1.json`, run the code, then check the output with `check-report.sh`. Don't put
  real data into the fake input.

## 3. Confirm, then create

After the publisher and site confirmation (step 2 of `SKILL.md`), show the plan and ask
for a yes:

> **Dynamic report** for **Acme Media** (acme.com): "Weekly revenue"
> Data: `revenue_by_day` (analytics aggregates, last 7 days), `gam_by_day` (Ad Manager,
> last 7 days)
> Schedule: every Monday at 06:00 Europe/London · visible until 2027-02-23
> The first version waits for your approval. Later versions publish automatically
> while the code and data stay unchanged and the safety scan is clean; anything else is
> held and tech@mile.tech is emailed. (yes / no)

**Schedules.** `frequency` is one of:
- `twice_daily`: every 12 hours from `time`. This is the fastest allowed.
- `daily` or `weekdays`.
- `weekly`, with `weekday`: 0 = Monday.
- `monthly`, with `month_day`: 1-31; short months use their last day.

Each schedule also has `time` (`HH:MM`, wall clock) and `timezone` (IANA name).

Then call `create_dynamic_report` with `publisher_id`, `site_id`, `title`,
`render_code`, `specs`, `schedule` and optionally `expires_in_days`. The expiry is fixed
when the report is created and is never extended, and nothing runs after it.

## 4. The first version

The first run is usually ready within 2 to 5 minutes. Poll `get_dynamic_report` every
30 seconds or so until the newest run is no longer `queued` or `running`:

- `held`: version 1 is uploaded and waits for approval. Continue with steps 4 and 5 of
  `SKILL.md`: `get_report_status`, size, hash and warnings, the preview link, and an
  explicit yes before `approve_report`. Approving starts the schedule. The operator can
  instead approve in the ADMOS UI (report page → *Review and approve*); if they prefer
  that, give them the report link and stop. Don't call `approve_report` as well.
- `failed`: show `error_code` and `error_detail`. For example, `render_failed` and
  `render_no_output` come with the Python traceback, and `iceberg_query_failed`,
  `iceberg_busy` or `gam_not_configured` with the source error. Fix
  the code or specs with `update_dynamic_report`, and a fresh first version is
  rendered. Failures are retried twice, ten minutes apart, before a run counts as
  failed.

## 5. Running it

- **Change the code or the specs**: `update_dynamic_report`. This needs approval again:
  a new first version is rendered and held, and the schedule stops until then.
- **Change only the schedule**: `update_dynamic_report` with `schedule`. No new approval
  is needed.
- **Pause, resume, stop or run now**: `control_dynamic_report`. `stop` is final; to
  restart, create a new report. The published version stays live in every case.
- **Status**: `get_dynamic_report` returns the state, the schedule, the next run and the
  last runs. Each run has its outcome, row counts and, for held or failed runs, the
  reason.
- Staff can do the same from the report's page in ADMOS. The Reports list has a
  Static / Dynamic filter, and the report page has a Schedule card and the run history.

A scheduled version is held instead of published if:
- the code or specs changed since the approval;
- the upload scan reports any warning; or
- the report names another publisher or site.

A person then approves that version with `approve_report`, after an explicit yes, as in
`SKILL.md`.
