---
name: price-sentinel
description: Agent-facing workflows for running Price Sentinel validation, scans, source diagnosis, config initialization, and result explanation through the local CLI.
---

# Price Sentinel Skill

Use this skill when the user wants a local agent to run or explain Price Sentinel workflows. Price Sentinel is product-neutral: use the `price-sentinel` CLI and Skill Command names, not product-specific command names.

The skill owns agent workflow guidance, prerequisites, and interpretation rules. The Price Sentinel CLI owns deterministic behavior: Source Extractors, Config Validation, Log Updates, Monitor State, locking, and Notification Transports. Do not reimplement or bypass those responsibilities in the agent.

## Safety Rule

Respect ADR-0001, "Do Not Bypass Blocked Sources." If a source is blocked by access denial, challenge pages, forbidden responses, protection timeouts, or similar barriers, report it as a Blocked Source. Agents may use explicitly configured public APIs or configured indirect sources, but do not bypass retailer protections with proxy rotation, CAPTCHA automation, challenge defeat, or similar workarounds.

## Inputs

Before running a command, identify the Active Config path. Only sources present in the Active Config are scanned or diagnosed. Starter Templates help initialize configs, but are never scanned implicitly.

Prefer the repository-local CLI when working from the project checkout:

```bash
bin/price-sentinel COMMAND
```

If the user has installed Price Sentinel elsewhere, use the installed `price-sentinel` command they specify.

## `validate`

Use `validate` before scan workflows, after editing an Active Config, and when the user asks whether a config is ready.

```bash
bin/price-sentinel validate --config PATH
```

Agent workflow:

1. Run validation against the Active Config path.
2. If validation succeeds, report the enabled check and source counts.
3. If validation fails, summarize the CLI errors and do not run a Scan until the user fixes the Active Config or asks for help editing it.
4. Do not perform independent config acceptance logic. Config Validation belongs to the CLI.

Disabled draft checks may remain incomplete if the CLI accepts them. Invalid enabled checks or enabled sources block scanning.

## Daily Scan Command

The Daily Scan Command is the normal recurring workflow for checking configured sources.

```bash
bin/price-sentinel validate --config PATH
bin/price-sentinel scan --config PATH
```

Agent workflow:

1. Run `validate` against the Active Config.
2. Run `scan` only after validation succeeds.
3. Let the CLI scan configured enabled sources, apply Source Extractors, update the Markdown Log, update Monitor State, hold locking, and deliver Notification Transports.
4. Summarize the scan with `explain-results`.
5. If the CLI reports an active scan lock, notification failure, validation failure, Blocked Sources, or source errors, report those outcomes without retry loops that would bypass CLI locking or source protections.

Normal scans must not mutate extractor logic or create new Source Extractors. Use `diagnose-source` for source investigation.

## `diagnose-source`

Use `diagnose-source` when the user asks why a configured source is failing, when an extractor may need maintenance, or when a new configured source needs evidence review.

```bash
bin/price-sentinel diagnose-source --config PATH --check CHECK_ID --source SOURCE_ID
```

Agent workflow:

1. Run the command for one enabled check/source pair from the Active Config.
2. Read the JSON evidence: source identity, requested and final URLs, HTTP status, page title, structured offer candidates, visible candidates, saved artifacts, and suggested extractor changes.
3. Explain what the diagnosis shows and whether a Source Extractor change appears needed.
4. Keep diagnosis separate from normal Scan behavior. Diagnosis may collect page evidence and suggest code changes, but it must not silently alter Source Extractors, run broad discovery, update the Markdown Log, write normal Monitor State, or send notifications.
5. If the diagnosis indicates a Blocked Source, apply the Safety Rule and do not bypass it.

## `init-config`

Use `init-config` when the user needs a new Active Config from a Starter Template.

```bash
bin/price-sentinel init-config --template NAME --config PATH
bin/price-sentinel validate --config PATH
```

Agent workflow:

1. Ask for the template name and destination path when interactive. In unattended runs, choose the narrowest reasonable Starter Template and record the assumption.
2. Create the Active Config with the CLI.
3. Run `validate` on the created config.
4. Tell the user that `examples/price-sentinel.example.yml` shows the supported config fields.
5. Do not scan the Starter Template itself and do not treat config initialization as a scheduled scan.

## `explain-results`

Use `explain-results` after a Scan or when the user asks what a recent Scan Report Block means. This is a Skill Command for agent summarization; it delegates facts to CLI output and the Markdown Log rather than performing extraction.

Summarize:

- Target-price hits: found results where price and required product constraints pass.
- Uncertain findings: results needing user review; do not count them as Target-Price Hits.
- Blocked Sources: sources the CLI classified as blocked; do not bypass them.
- Errors: source or workflow failures that need config, extractor, network, notification, or operational attention.
- Log and state updates: mention the Markdown Log path, Monitor State path, notification count, and lock errors when present in CLI output.

Keep explanations concise and source-grounded. If a requested conclusion is not supported by CLI output, the Markdown Log, or diagnosis evidence, say what is unknown.

## Scheduler Integration

Scheduling is external to the Price Sentinel CLI in v1. Configure a scheduler to invoke the Daily Scan Command rather than embedding scheduling behavior in the agent or CLI.

Supported integration options:

- Codex automation: create a recurring automation that runs the Daily Scan Command and reports the `explain-results` summary.
- Claude Code scheduled task: create a scheduled task that invokes `/price-sentinel scan --config PATH` for the Active Config.
- cron: schedule a shell command that runs validation and scan from the project checkout with explicit config paths.
- launchd: create a local LaunchAgent for macOS hosts that invokes the same validation and scan commands on the desired cadence.

Whichever scheduler is used, keep the Active Config path explicit, preserve CLI locking, and let the CLI own Log Updates, Monitor State, and Notification Transports.
