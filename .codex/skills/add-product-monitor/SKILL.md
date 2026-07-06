---
name: add-product-monitor
description: End-to-end workflow for adding a new product monitor to Price Sentinel, including a user interview, config authoring, extractor selection, browser source validation, CLI verification, and tests.
---

# Add Product Monitor Skill

Use this skill when the user asks to monitor a new product with Price Sentinel. It walks one product from interview to a validated, scanned, tested monitor config. For day-to-day operation of an existing config, use the `price-sentinel` skill instead.

The Price Sentinel CLI owns deterministic behavior: Source Extractors, Config Validation, Log Updates, Monitor State, locking, and Notification Transports. This skill only orchestrates the setup workflow around the CLI.

## Safety Rule

Respect ADR-0001, "Do Not Bypass Blocked Sources." During source validation, do not bypass blocked pages, CAPTCHAs, bot checks, or access controls. If a page is blocked, record it as a Blocked Source, leave the source disabled or remove it, and choose an approved alternative source when possible.

## Step 1: Interview the User

Interview before creating anything. Ask only the questions needed to build a valid monitor config:

- product name
- country / shipping region
- currency
- target price
- acceptable condition values, such as `new`, `refurbished`, `used`, `open_box`
- acceptable sellers, if any
- required product identity attributes, such as brand, model, size, storage, color, SKU
- preferred retailers or URLs
- whether search result pages are acceptable or only explicit product pages
- whether draft sources should stay disabled until validated
- whether to add the monitor as a new check in an existing config or create a new config file
- run id strategy: a static `run_id` (each scan replaces its previous Markdown Log entry, keeping one merged report) or an automatic timestamped run id (`run_id: null`; each scan appends a new log entry)

When running unattended, pick the most reasonable interpretation, proceed, and record the assumptions in the final summary.

## Step 2: Ask About Notifications

Ask whether the user wants notifications. If yes, ask for:

- ntfy topic
- ntfy server, defaulting to `https://ntfy.sh`
- optional `token_env` for protected topics
- which categories to notify on: `hits`, `errors`, `uncertain`, `blocked`, `scan_summary`

Remind the user that public ntfy topics behave like shared secrets: use a long, hard-to-guess topic name. Do not enable `alerts` until the ntfy transport config is complete and valid; until then keep `alerts.enabled: false` or the transport `enabled: false`.

## Step 3: Create or Update the Active Config

Author the Active Config using the structure in `examples/price-sentinel.example.yml` (the authoritative list of fields the current CLI reads) and `config/macbook-air-buying-guide.yml` (a real multi-check example):

- `run`, `state`, `output`, optional `diagnostics`, `alerts`, and `checks[]` with `sources[]`
- set `run.run_id` from the interview: the static value the user chose, or `null` for automatic timestamped run ids
- stable kebab-case ids for checks, sources, and transports
- per-config `state.dir` and `output.markdown_log` paths so configs do not collide
- only fields the current CLI reads; do not invent fields
- keep useful-but-unvalidated sources as disabled drafts (`enabled: false`)
- `retailer` is a display label only; it never changes extraction behavior. When a source needs non-default extraction semantics, set the explicit per-source fields (see the README `checks[].sources[]` table):
  - `price_unit: cents` when the site embeds integer cent prices in JSON (for example Reebelo's Shopify embeds store `184900` for $1,849.00); validation rejects values other than `cents`/`dollars`
  - `currency_default` when pages omit currency and the `.ca`/`expected_country` CAD fallback is wrong (for example OWC MacSales prices are USD)
  - `seller_default` when the check uses `seller.allow` and pages do not state a seller (typical for search-result sources)
  - `availability_default` when pages omit availability but it is implied (for example eBay search results only list live items → `in_stock`)

## Step 4: Choose Source Extractors

Supported extractors, defined in `lib/price_sentinel/source_extractors.rb`:

- `generic_product_page` — JSON-LD Product or product meta tag extraction; default choice
- `apple_ca_product_page` — Apple Canada pages with Apple defaults
- `amazon_ca_search` — Amazon.ca search results parsed directly from the page's result tiles; plain HTTP, no API key
- `firecrawl_ebay_search` — eBay.ca search results via Firecrawl; requires `FIRECRAWL_API_KEY`
- `walmart_ca_search` — Walmart.ca search results parsed from the page's `__NEXT_DATA__` payload; plain HTTP, no browser needed
- `bestbuy_ca_search` — Best Buy Canada search results via the site's public JSON search API; pair with `availability_default: in_stock`
- `staples_ca_search` — Staples.ca search results via the site's public Algolia index; bypasses the Cloudflare-protected storefront
- `fake_source` — tests only; never use it in a real monitor config

Try `generic_product_page` first for new retailers. If existing extractors cannot extract reliable prices for a selected source, add the minimal custom extractor support in `lib/price_sentinel/source_extractors.rb` and register it in `SUPPORTED_NAMES`. Use `diagnose-source` evidence to justify the change. Do not add broad brittle scraping when the generic JSON-LD/meta extraction path is enough.

## Step 5: Validate Sources with Browser Evidence

For every source in the new product config, open the URL in a browser or browser automation and confirm:

- the page is reachable
- it is the intended product page or a useful search page
- visible price evidence exists, or explain why the source stays disabled/draft

Apply the Safety Rule: if blocked, report it as a Blocked Source and do not bypass it.

## Step 6: Run Price Sentinel Commands

Use the repository-local CLI. Validate first, diagnose new or uncertain sources, and scan only after validation succeeds:

```bash
bin/price-sentinel validate --config PATH
bin/price-sentinel diagnose-source --config PATH --check CHECK_ID --source SOURCE_ID
bin/price-sentinel scan --config PATH
```

If the execution environment restricts outbound network access, request network approval before running `diagnose-source` or `scan`. After scanning, summarize target-price hits, uncertain findings, blocked sources, errors, Markdown Log changes, Monitor State, and notification behavior, as described by the `price-sentinel` skill's `explain-results` command.

## Step 7: Add Tests

Add focused Minitest coverage in `test/` for whatever this workflow changed:

- config validation for any new extractor name or config fields
- scanner behavior for any new extractor path
- blocked/uncertain/error handling where relevant
- notification config behavior if changed
- skill documentation/command contract if skill text changed

Prefer fixtures and deterministic fake HTTP responses over live network tests. If only a config file was added, no new tests are required.

## Step 8: Update Documentation

Only where needed: if a new extractor was added, update the README Supported Extractors table and any project-local skill docs that list extractors. Do not add extra docs.

## Step 9: Verify Before Finishing

Run the full test suite:

```bash
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

Also run validate, diagnose-source for new sources, and scan against the new product config when network access is available.

Finish with a short summary listing exact files changed, commands run, results, sources left disabled or blocked, and anything not done.
