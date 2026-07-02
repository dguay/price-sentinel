# frozen_string_literal: true

require "minitest/autorun"

class SkillDocumentationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SKILL_PATH = File.join(ROOT, ".codex", "skills", "price-sentinel", "SKILL.md")
  CLAUDE_SKILL_DIR = File.join(ROOT, ".claude", "skills", "price-sentinel")
  CLAUDE_SKILL_PATH = File.join(CLAUDE_SKILL_DIR, "SKILL.md")
  README_PATH = File.join(ROOT, "README.md")
  CONTEXT_PATH = File.join(ROOT, "CONTEXT.md")

  def skill_doc
    File.read(SKILL_PATH)
  end

  def section(doc, heading)
    match = doc.match(/^## #{Regexp.escape(heading)}\n(?<body>.*?)(?=^## |\z)/m)
    assert match, "expected #{heading} section"
    match[:body]
  end

  def test_price_sentinel_skill_documents_required_agent_workflows
    assert File.exist?(SKILL_PATH), "expected Price Sentinel Skill at #{SKILL_PATH}"

    doc = skill_doc

    validate = section(doc, "`validate`")
    daily_scan = section(doc, "Daily Scan Command")
    diagnosis = section(doc, "`diagnose-source`")
    init_config = section(doc, "`init-config`")
    explanation = section(doc, "`explain-results`")

    assert_includes doc, "Source Extractors"
    assert_includes doc, "Config Validation"
    assert_includes doc, "Log Updates"
    assert_includes doc, "Monitor State"
    assert_includes doc, "locking"
    assert_includes doc, "Notification Transports"
    assert_includes(
      doc,
      "The Price Sentinel CLI owns deterministic behavior: Source Extractors, Config Validation, Log Updates, Monitor State, locking, and Notification Transports"
    )

    assert_includes validate, "bin/price-sentinel validate --config PATH"
    assert_includes validate, "do not run a Scan"
    assert_includes validate, "Config Validation belongs to the CLI"

    validate_index = daily_scan.index("bin/price-sentinel validate --config PATH")
    scan_index = daily_scan.index("bin/price-sentinel scan --config PATH")
    assert validate_index, "expected Daily Scan Command to validate first"
    assert scan_index, "expected Daily Scan Command to scan after validation"
    assert_operator validate_index, :<, scan_index
    assert_includes daily_scan, "Run `scan` only after validation succeeds"
    assert_includes daily_scan, "Normal scans must not mutate extractor logic"

    assert_includes diagnosis, "bin/price-sentinel diagnose-source --config PATH --check CHECK_ID --source SOURCE_ID"
    assert_includes diagnosis, "one enabled check/source pair"
    assert_includes diagnosis, "Keep diagnosis separate from normal Scan behavior"
    assert_includes diagnosis, "must not silently alter Source Extractors"
    assert_includes diagnosis, "update the Markdown Log"
    assert_includes diagnosis, "write normal Monitor State"
    assert_includes diagnosis, "send notifications"

    assert_includes init_config, "bin/price-sentinel init-config --template NAME --config PATH"
    assert_includes init_config, "bin/price-sentinel validate --config PATH"
    assert_includes init_config, "Do not scan the Starter Template"

    assert_includes explanation, "Target-price hits"
    assert_includes explanation, "Uncertain findings"
    assert_includes explanation, "do not count them as Target-Price Hits"
    assert_includes explanation, "Blocked Sources"
    assert_includes explanation, "do not bypass them"
    assert_includes explanation, "Errors"

    safety = section(doc, "Safety Rule")
    assert_includes safety, "Do Not Bypass Blocked Sources"
    assert_includes safety, "Blocked Source"
    assert_includes safety, "do not bypass retailer protections"

    scheduler = section(doc, "Scheduler Integration")
    assert_includes scheduler, "external to the Price Sentinel CLI"
    assert_includes scheduler, "Codex automation"
    assert_includes scheduler, "Claude Code scheduled task"
    assert_includes scheduler, "cron"
    assert_includes scheduler, "launchd"

    command_lines = doc.scan(/^bin\/\S+(?: .*)?$/)
    refute_empty command_lines
    command_lines.each do |line|
      assert_match(/\Abin\/price-sentinel(?:\s+(?:COMMAND|validate|scan|diagnose-source|init-config)\b|\z)/, line)
    end
    refute_match(/^bin\/(?!price-sentinel\b)/, doc)
    refute_includes doc, "macbook-price"
    refute_match(/macbook/i, doc)
  end

  def test_price_sentinel_skill_is_available_to_claude_code
    assert File.exist?(SKILL_PATH), "expected Codex skill at #{SKILL_PATH}"
    assert File.symlink?(CLAUDE_SKILL_DIR), "expected Claude Code skill directory to be a symlink at #{CLAUDE_SKILL_DIR}"
    assert File.exist?(CLAUDE_SKILL_PATH), "expected Claude Code skill at #{CLAUDE_SKILL_PATH}"

    assert File.identical?(SKILL_PATH, CLAUDE_SKILL_PATH), "expected Claude Code skill to resolve to the Codex skill"
  end

  def test_documentation_lists_codex_and_claude_code_skill_locations
    readme = File.read(README_PATH)
    context = File.read(CONTEXT_PATH)

    assert_includes readme, ".codex/skills/price-sentinel/SKILL.md"
    assert_includes readme, ".claude/skills/price-sentinel/SKILL.md"
    assert_includes readme, "/price-sentinel"
    assert_includes readme, "Claude Code"

    assert_includes context, ".codex/skills/price-sentinel/SKILL.md"
    assert_includes context, ".claude/skills/price-sentinel/SKILL.md"
    assert_includes context, "Claude Code"
  end
end
