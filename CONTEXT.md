# Price Sentinel

A local workflow for checking configured product prices from user-selected sources and logging the newest scan results first. MacBooks are the first use case, not the boundary of the domain.

## Language

**Price Sentinel Skill**:
A local agent skill, available to Codex at `.codex/skills/price-sentinel/SKILL.md` and to Claude Code at `.claude/skills/price-sentinel/SKILL.md`, that instructs an LLM-enabled local agent how to run the Price Sentinel workflow. It owns workflow guidance, prerequisites, interpretation rules, and when to update the Markdown log. It does not own retailer extraction logic.

**Add Product Monitor Skill**:
A local agent skill, available to Codex at `.codex/skills/add-product-monitor/SKILL.md` and to Claude Code at `.claude/skills/add-product-monitor/SKILL.md`, that guides an agent through adding a new product monitor end to end: user interview, config authoring, extractor selection, browser source validation, CLI verification, and tests.

**Price Sentinel CLI**:
A local script or command-line tool that owns retailer extraction, config parsing, price normalization, scan output, and Markdown log updates.

**Scan**:
A single execution of the Price Sentinel CLI against the configured products and sources.

**Markdown Log**:
The user-facing Markdown file where scan results are prepended so the newest run appears first.

**URL-Based Check**:
A configured check where each source points at a specific product or retailer page for the intended product. _Avoid_: broad discovery check, search scrape

**Scan Result State**:
The classification assigned to one source during a Scan: found, no_match, uncertain, blocked, or error. Uncertain findings are logged for review but do not count as target-price hits.

**Target-Price Hit**:
A found Scan Result where the normalized price is at or below the configured target price and all required product constraints pass. Price alone is not enough.

**Product Constraint**:
A required fact that must hold before a found price can become a Target-Price Hit, such as currency, condition, memory, storage, seller, or Canada shipping eligibility.

**Observed Product**:
The product identity the scanner believes it found at a configured source, including the facts needed to compare it with the intended product.

**Common Product Facts**:
Product facts that apply across most categories, such as price, currency, condition, seller, availability, and shipping region.

**Product Attributes**:
Flexible category-specific facts used to identify the intended product, such as laptop memory, storage, screen size, chip, brand, or model.

**Source Extractor**:
A deterministic retailer-specific parser used for normal scans. LLM-assisted Playwright inspection is reserved for diagnostics, new source setup, and broken extractor investigation.

**Log Update**:
The deterministic operation of writing a Scan result block to the Markdown Log. The Price Sentinel CLI owns this operation; the Price Sentinel Skill only instructs the agent when and how to invoke it.

**Run ID**:
A stable identifier for one Scan attempt, used to replace an existing Markdown Log block when the same run is retried.

**Blocked Source**:
A configured source that cannot be accessed because of an access denial, challenge page, forbidden response, timeout caused by protection, or similar barrier. A Blocked Source is reported as blocked rather than bypassed.

**Active Config**:
The configuration file used for a Scan. Only sources present in the Active Config are scanned.

**Starter Template**:
An example configuration that helps the user create an Active Config. A Starter Template is never scanned implicitly.

**Config Validation**:
The pre-scan check that ensures every enabled check and source is complete, coherent, and supported. Invalid enabled configuration blocks the Scan; disabled checks may remain incomplete.

**Skill Command**:
A named workflow command documented by the Price Sentinel Skill, such as validate, scan, or diagnose-source. Skill Commands invoke the Price Sentinel CLI but define the agent-facing intent and expected behavior.

**Source Diagnosis**:
A Skill Command and CLI workflow for investigating a source or authoring a Source Extractor. It collects page evidence and suggested extractor changes, but normal scans do not mutate extractor logic.

**Daily Scan Command**:
The primary everyday Skill Command. It validates the Active Config, runs the Scan, updates the Markdown Log, and summarizes hits, uncertain findings, blocked sources, and errors.

**Price Sentinel Command Namespace**:
The product-neutral Skill Command namespace for this workflow. _Avoid_: macbook-price

**Scan Report Block**:
The Markdown block written for one Scan. It is optimized for human reading and may include compact embedded JSON for later machine analysis.

**Notification Transport**:
A configured delivery mechanism for scan notifications. ntfy is the first supported transport.

**ntfy Topic**:
The topic name used to publish ntfy notifications. It should be hard to guess because the topic effectively acts as a shared secret.

**Monitor State**:
Local runtime data such as notification dedupe history and last scan metadata. It defaults beside the Active Config and may be overridden with explicit paths.

**Scheduler Integration**:
An external mechanism that invokes a Skill Command on a cadence, such as a Codex automation, Claude Code scheduled task, cron, launchd, or another local automation tool. Scheduling is not owned by the Price Sentinel CLI in v1.
