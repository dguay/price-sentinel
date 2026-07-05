# Price Sentinel

![Ruby](https://img.shields.io/badge/Ruby-stdlib-red)
![CLI](https://img.shields.io/badge/CLI-OptParse-blue)
![Config](https://img.shields.io/badge/Config-YAML-yellow)
![Tests](https://img.shields.io/badge/Tests-Minitest-green)
![Notifications](https://img.shields.io/badge/Notifications-ntfy-lightgrey)

Price Sentinel is a local Ruby CLI for monitoring explicit product sources against
target prices. It validates an active YAML config, scans enabled product sources,
classifies each result, prepends a scan report to a Markdown log, records local
monitor state, and can send ntfy notifications for useful scan events.

The first real use case is Canada-focused product price monitoring, but the tool
is product-neutral. You decide which products and URLs are scanned by listing
them in an active config file.

## What It Does

- Checks only the enabled checks and sources in the active config you pass with
  `--config`.
- Supports deterministic source extractors for normal scans.
- Treats uncertain findings as review items, not as target-price hits.
- Reports blocked sources instead of trying to bypass access controls.
- Prepends scan report blocks to a Markdown log when configured.
- Writes local runtime state for last scans, scan locking, and notification
  dedupe.
- Sends ntfy notifications when alerts are enabled.
- Keeps scheduling external. Use Codex automation, Claude Code scheduled tasks,
  cron, launchd, or another scheduler to run the CLI on a cadence.

## How the Agent Skill Works

This repository includes two skills exposed through both supported
local-agent layouts:

- Codex: `.codex/skills/price-sentinel/SKILL.md`
- Claude Code: `.claude/skills/price-sentinel/SKILL.md`

A second skill, `add-product-monitor`, guides an agent through adding a new
product monitor end to end: interviewing the user, authoring the config,
choosing extractors, validating sources in a browser, running the CLI, and
adding tests:

- Codex: `.codex/skills/add-product-monitor/SKILL.md`
- Claude Code: `.claude/skills/add-product-monitor/SKILL.md`

The Claude Code skill path is a project-local skill entry that points at the same
instructions as the Codex skill, so both agents use the same workflow contract.
The skill is guidance for local agents; the Ruby CLI is the deterministic
implementation.

The skill tells an agent to:

- identify the active config path before running workflows;
- use the `validate`, `init-config`, `diagnose-source`, Daily Scan, and
  `explain-results` Skill Commands by name;
- run the daily workflow as validate first, scan second;
- summarize scan output in terms of target-price hits, uncertain findings,
  blocked sources, errors, Markdown log updates, monitor state, and
  notifications;
- use `diagnose-source` for source evidence and extractor investigation; and
- respect the blocked-source safety rule instead of bypassing retailer
  protections.

The skill does not parse retailer pages, decide whether configs are valid,
update logs, manage locks, or send notifications. Those responsibilities belong
to the CLI.

When working in Codex or Claude Code, use the `/price-sentinel` skill command
instead of typing the underlying shell command. For example:

```text
/price-sentinel init-config --template generic-product --config config/price-sentinel.yml
```

The agent will follow the skill workflow and run the repository-local CLI under
the hood.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `bin/price-sentinel` | CLI entrypoint. |
| `lib/price_sentinel/config_validator.rb` | YAML config validation. |
| `lib/price_sentinel/scanner.rb` | Scan orchestration and hit classification. |
| `lib/price_sentinel/source_extractors.rb` | Supported source extractors. |
| `lib/price_sentinel/markdown_log.rb` | Markdown scan report writer. |
| `lib/price_sentinel/monitor_state.rb` | Locking and local state files. |
| `lib/price_sentinel/notifications.rb` | ntfy notification delivery and dedupe. |
| `lib/price_sentinel/source_diagnosis.rb` | Source diagnosis evidence collection. |
| `templates/starter/` | Starter active config templates. |
| `examples/price-sentinel.example.yml` | Example config using supported fields. |
| `test/` | Minitest coverage for CLI workflows. |

## Requirements

- Ruby with the standard library. The current implementation does not require
  bundled gems.
- Network access from the machine running scans for live product sources and ntfy
  notifications.
- A scheduler if you want recurring scans. The CLI does not schedule itself.

## Installation

Clone the repository and enter the project checkout:

```bash
git clone git@github.com:dguay/price-sentinel.git
cd price-sentinel
```

Confirm Ruby is available:

```bash
ruby --version
```

No gem installation step is required. The CLI uses only Ruby standard library
components and can be run directly from the checkout. Use the generic starter
template as a non-mutating smoke test:

```bash
bin/price-sentinel validate --config templates/starter/generic-product.yml
```

Run the test suite after installation:

```bash
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Codex and Claude Code discover the project-local skill from this checkout:

- Codex: `.codex/skills/price-sentinel/SKILL.md`
- Claude Code: `.claude/skills/price-sentinel/SKILL.md`

## First Time Setup

1. Create an active config from a starter template:

   ```text
   /price-sentinel init-config --template generic-product --config config/price-sentinel.yml
   ```

   Available templates:

   - `generic-product`
   - `macbook-canada`

2. Edit the generated config:

   - Set each check's `product_name`, `target`, `required`, and `attributes`.
   - Replace each source `url` with an explicit product or retailer page.
   - Set `output.markdown_log` to the Markdown file you want updated.
   - Leave `alerts.enabled: false` until you have configured a real ntfy topic.

3. Validate the config:

   ```text
   /price-sentinel validate --config config/price-sentinel.yml
   ```

4. Run the first scan with the Daily Scan Command:

   ```text
   /price-sentinel scan --config config/price-sentinel.yml
   ```

5. If the scan works, schedule the same validate-then-scan sequence with your
   scheduler of choice.

## Skill Commands

Use `/price-sentinel` commands when asking Codex or another local agent to
operate Price Sentinel. These commands are the user-facing interface. They
delegate deterministic work to the repository-local CLI; they are not a separate
executable.

### `init-config`

Creates a new active config by copying a starter template.

```text
/price-sentinel init-config --template NAME --config PATH
```

Required options:

| Option | Description |
| --- | --- |
| `--template NAME` | Starter template name. Use `generic-product` or `macbook-canada`. |
| `--config PATH` | Destination path for the active config. The command refuses to overwrite an existing file. |

Use this when setting up a new watch file. After creation, edit the generated
config and run `validate`. Starter templates are examples only; scans use the
active config path you pass to the skill.

### `validate`

Validates an active config without scanning sources.

```text
/price-sentinel validate --config PATH
```

Validation currently checks:

- The config root is a YAML mapping.
- `checks` entries and `sources` entries have the expected mapping shape.
- Enabled checks have `target.amount`, `target.currency`, and at least one
  enabled source.
- Enabled sources use a supported extractor and an absolute `http` or `https`
  URL.
- Enabled ntfy transports have type `ntfy`, a topic, and an absolute `http` or
  `https` server URL.

Disabled draft checks and disabled draft sources may remain incomplete.

### Daily Scan Command

Validates the config, acquires a scan lock, scans enabled sources, prints a
summary, updates the Markdown log, sends notifications, and records last-scan
state.

```text
/price-sentinel scan --config PATH
```

Use `/price-sentinel scan` as the Daily Scan Command for normal recurring
monitoring. The skill validates first and scans only after validation succeeds.
A result becomes a target-price hit only when:

- the extractor returns state `found`;
- the extracted price currency matches the target currency;
- the extracted amount is at or below `target.amount`;
- required product constraints pass; and
- configured product attributes match the observed product attributes.

Result states:

| State | Meaning |
| --- | --- |
| `found` | Price data was extracted. It may or may not be a target-price hit. |
| `no_match` | The source was scanned but did not match the intended product. |
| `uncertain` | The source produced evidence that needs review. This never counts as a hit. |
| `blocked` | The source appears access denied, challenged, forbidden, rate limited, or otherwise blocked. |
| `error` | The source or scan workflow failed. |

### `diagnose-source`

Fetches one enabled source and prints JSON evidence for extractor maintenance or
source investigation.

```text
/price-sentinel diagnose-source --config PATH --check CHECK_ID --source SOURCE_ID
```

Use this when a source is failing, uncertain, new, or likely needs extractor
work. Diagnosis reports source identity, requested URL, final URL, HTTP status,
page title, structured offer candidates, visible candidates, and suggested next
steps. When configured, it can save fetched HTML artifacts.

Diagnosis does not run a normal scan, update the Markdown log, write last-scan
state, or send notifications.

## Supported Extractors

| Extractor | Purpose |
| --- | --- |
| `generic_product_page` | Fetches a product page and extracts price data from JSON-LD Product data or Open Graph style product meta tags. |
| `apple_ca_product_page` | Uses the generic product page extraction path with Apple Canada defaults for condition, seller, and brand. |
| `firecrawl_amazon_search` | Uses Firecrawl as an explicitly configured indirect source for Amazon.ca search-result pages and extracts structured product candidates. Falls back to markdown parsing when LLM JSON extraction returns null (e.g. for large or complex pages). Requires `FIRECRAWL_API_KEY` in the environment or `.env`. |
| `fake_source` | Test-only extractor for deterministic scan states in automated tests. |

Normal scans use deterministic extractors. Do not use automation to bypass
retailer protections when a source is blocked.

## Active Config Reference

The example config lives at `examples/price-sentinel.example.yml`. It includes
only fields read by the current CLI.

### Top Level

| Field | Required | Used by CLI | Description |
| --- | --- | --- | --- |
| `run` | Optional | Yes | Scan run behavior such as explicit run ID and stale lock threshold. |
| `state` | Optional | Yes | Local state directory and file names. |
| `output` | Optional | Yes | Markdown log and report output behavior. |
| `alerts` | Optional | Yes | ntfy notification policy and transports. |
| `checks` | Required for useful scans | Yes | Product checks and their sources. |
| `diagnostics` | Optional | Yes for `diagnose-source` | Top-level diagnosis artifact settings. |

### `run`

| Field | Used by CLI | Description |
| --- | --- | --- |
| `run_id` | Yes | Optional stable ID for a scan. If omitted, the CLI generates `scan-YYYYMMDDTHHMMSSNZ`. Reusing a run ID replaces that run's existing Markdown block. |
| `stale_lock_after_ms` | Yes | Age after which a lock payload is considered stale. Defaults to `1800000` ms. |

### `state`

Relative paths are resolved from the active config file's directory.

| Field | Default | Description |
| --- | --- | --- |
| `dir` | `.price-sentinel` beside the active config | Base directory for default state files. |
| `alert_state_file` | `alert-state.json` | Notification dedupe state file. |
| `last_scan_file` | `last-scan.json` | Last scan report state file. |
| `lock_file` | `scan-<config-name>-<digest>.lock` | Active scan lock file. The default includes a digest of the full config path so different configs do not collide. |

### `output`

| Field | Used by CLI | Description |
| --- | --- | --- |
| `markdown_log` | Yes | Markdown log path. Relative paths resolve from the active config file's directory. If blank or omitted, no Markdown log is written. |
| `include_json` | Yes | When `true`, embeds compact JSON for the scan report in the Markdown block. |

### `alerts`

| Field | Used by CLI | Description |
| --- | --- | --- |
| `enabled` | Yes | Enables notification handling when `true`. If omitted on the alerts mapping, it behaves as enabled. |
| `notify_on` | Yes | Category toggles for notifications. |
| `dedupe` | Yes | Hit notification dedupe policy and state behavior. |
| `transports` | Yes | Notification transports. Only `ntfy` is supported. |

Default `notify_on` values:

| Field | Default | Description |
| --- | --- | --- |
| `hits` | `true` | Notify for target-price hits. |
| `errors` | `true` | Notify for error results. |
| `uncertain` | `false` | Notify for uncertain findings. |
| `blocked` | `false` | Notify for blocked sources. |
| `scan_summary` | `false` | Send a scan summary notification. |

### `alerts.dedupe`

| Field | Used by CLI | Description |
| --- | --- | --- |
| `enabled` | Yes | Defaults to `true`. When disabled, every target-price hit is a notification candidate. |
| `notify_when` | Yes | Hit reasons that should notify. Defaults to `first_hit_for_check_source`, `price_drops`, and `reentered_hit_state`. |
| `price_drop_threshold.amount` | Yes | Minimum drop required for a `price_drops` notification. If omitted or zero, any lower price qualifies. |

Supported `notify_when` values:

| Value | Meaning |
| --- | --- |
| `first_hit_for_check_source` | Notify when a check/source hits for the first time. |
| `price_drops` | Notify when an already-hit source drops by the configured threshold. |
| `reentered_hit_state` | Notify when a source that had stopped hitting becomes a hit again. |

### `alerts.transports[]`

Only ntfy transports are supported.

| Field | Required when enabled | Description |
| --- | --- | --- |
| `id` | Recommended | Human-readable transport ID used in validation and error messages. |
| `type` | Yes | Must be `ntfy`. |
| `enabled` | No | Defaults to enabled. Set `false` to keep a draft transport. |
| `topic` | Yes | ntfy topic. Treat public ntfy topics like shared secrets and use a long random value. |
| `server` | Yes | Absolute ntfy server URL, for example `https://ntfy.sh`. |
| `priority` | No | Sent as the ntfy `Priority` header. |
| `tags` | No | Sent as a comma-separated ntfy `Tags` header. |
| `title_template` | No | Template for the ntfy `Title` header. |
| `message_template` | No | Template for the ntfy message body. |
| `click` | No | Sent as the ntfy `Click` header. |
| `token_env` | No | Environment variable containing a bearer token. |

Template variables:

| Variable | Description |
| --- | --- |
| `{{run_id}}` | Current scan run ID. |
| `{{category}}` | Notification category such as `hit`, `error`, `uncertain`, `blocked`, or `scan_summary`. |
| `{{reason}}` | Dedupe reason for hit notifications when present. |
| `{{check.id}}` | Check ID. |
| `{{check.product_name}}` | Check product name. |
| `{{source.id}}` | Source ID. |
| `{{source.retailer}}` | Source retailer. |
| `{{source.url}}` | Source URL. |
| `{{result.state}}` | Result state. |
| `{{result.message}}` | Result message. |
| `{{price.currency}}` | Result price currency. |
| `{{price.amount}}` | Result price amount. |

### `checks[]`

Each enabled check represents one intended product and one or more explicit
sources to scan.

| Field | Required when enabled | Used by CLI | Description |
| --- | --- | --- | --- |
| `id` | Recommended | Yes | Stable check ID used in output, state, and logs. |
| `enabled` | No | Yes | Defaults to enabled. Set `false` to keep an incomplete draft. |
| `product_name` | Recommended | Yes | Human-readable product name used in reports and notifications. |
| `target.amount` | Yes | Yes | Target price amount. |
| `target.currency` | Yes | Yes | Target price currency. |
| `required` | No | Yes | Required product constraints before a found result can become a hit. |
| `attributes` | No | Yes | Product identity attributes. Non-null expected values must match observed attributes. |
| `sources` | Yes | Yes | Source list. Enabled checks need at least one enabled source. |

### `checks[].required`

| Field | Description |
| --- | --- |
| `currency` | Required currency for the extracted price. |
| `ships_to` | Required shipping country or region code. |
| `condition.allow` | Allowed observed condition values, such as `new`, `refurbished`, or `used`. Empty or omitted means no condition restriction. |
| `seller.allow` | Allowed observed seller names. Empty or omitted means no seller restriction. |
| `availability.allow` | Allowed observed availability values, such as `in_stock` or `available`. Empty or omitted means no availability restriction. |

### `checks[].attributes`

Attributes are flexible product identity fields. Current extractors can observe
MacBook-oriented fields such as:

| Field | Description |
| --- | --- |
| `category` | Product category, for example `laptop`. |
| `brand` | Brand name. |
| `product_line` | Product line such as `MacBook Air`. |
| `model` | Model descriptor such as `15-inch`. |
| `chip` | Chip descriptor such as `M4`. |
| `memory_gb` | Memory capacity in GB. |
| `storage_gb` | Storage capacity in GB. |
For hit classification, any attribute with a non-null expected value must match
the observed attribute value. Null attributes are ignored. Do not store human
notes or buying-guide metadata under `attributes`; the scanner treats them as
product identity constraints.

### `checks[].sources[]`

| Field | Required when enabled | Used by CLI | Description |
| --- | --- | --- | --- |
| `id` | Recommended | Yes | Stable source ID used in output, state, and logs. |
| `enabled` | No | Yes | Defaults to enabled. Set `false` to keep a draft source. |
| `retailer` | Recommended | Yes | Retailer label used in reports and notifications. |
| `extractor` | Yes | Yes | Supported extractor name. |
| `url` | Yes | Yes | Absolute `http` or `https` URL. |
| `expected_country` | Recommended | Yes | Used as observed `ships_to` by generic extraction. |
| `diagnostics` | Optional | Yes for `diagnose-source` | Source-level diagnosis artifact settings. |
| `fake_result` | Test configs only | Yes for `fake_source` | Deterministic result payload for tests. |

### `diagnostics`

Diagnosis settings may appear at the top level or under a source. Source-level
values override top-level values.

| Field | Used by CLI | Description |
| --- | --- | --- |
| `save_html` | Yes | When `true`, diagnosis saves fetched HTML. |
| `artifact_dir` | Yes | Directory for saved diagnosis artifacts. Relative paths resolve from the active config file's directory. Defaults to `.price-sentinel/diagnostics`. |

## Markdown Log

When `output.markdown_log` is configured, scans prepend a report block containing:

- run ID;
- summary counts;
- target-price hits;
- uncertain findings;
- blocked sources;
- errors; and
- optional embedded JSON when `output.include_json: true`.

If a scan uses the same `run_id` as an existing block, that block is replaced.
Different run IDs are prepended above older runs.

## Monitor State and Locking

Every scan uses a lock file so one config is not scanned concurrently. If a lock
exists and is not stale, the scan exits without mutating the Markdown log. Stale
lock recovery is controlled by `run.stale_lock_after_ms`.

After a scan, the CLI writes last-scan JSON state and, when notifications are
enabled, alert dedupe state.

## Notifications

Price Sentinel currently supports ntfy. To enable it:

```yaml
alerts:
  enabled: true
  notify_on:
    hits: true
    errors: true
  transports:
    - id: personal-ntfy
      type: ntfy
      enabled: true
      topic: replace-with-long-random-topic
      server: https://ntfy.sh
```

For private ntfy servers or protected topics, set `token_env` to an environment
variable name containing the bearer token.

## Scheduling

The CLI does not schedule itself. Schedule an agent workflow that uses the
Price Sentinel skill's Daily Scan Command for the active config path:

```text
/price-sentinel scan --config config/price-sentinel.yml
```

The Daily Scan Command validates first and scans only after validation succeeds.

## Development

Run the test suite with:

```bash
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Run a focused test file with:

```bash
ruby -Itest test/cli_scan_test.rb
```

The project uses Ruby standard library components including `OptionParser`,
`YAML`, `Net::HTTP`, `JSON`, and `Minitest`.

## Safety Notes

Price Sentinel reports blocked sources. Do not use proxy rotation, CAPTCHA
automation, challenge defeat, or similar workarounds to bypass retailer
protections. Use explicitly configured public APIs or approved indirect sources
when available.

## Common Troubleshooting

| Symptom | What to check |
| --- | --- |
| `Config invalid` | Run `validate` and fix each reported field. Enabled checks and sources must be complete. |
| `sources must include at least one enabled source` | Add a source or set the check to `enabled: false` while drafting. |
| `extractor is unknown` | Use one of the supported extractor names. |
| `url must be an absolute http(s) URL` | Use a full URL beginning with `http://` or `https://`. |
| Scan reports `blocked` | Treat the source as blocked and do not bypass access controls. |
| Scan reports `uncertain` | Run `diagnose-source` for the check/source pair and inspect the evidence. |
| No Markdown log is written | Set `output.markdown_log` in the active config. |
| Repeated scans replace a block | Check whether `run.run_id` is fixed. Reusing a run ID intentionally replaces the same report block. |
