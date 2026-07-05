# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class CliValidateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "price-sentinel")

  def run_cli(*args)
    Open3.capture3(CLI, *args)
  end

  def with_config(config)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "active.yml")
      File.write(path, YAML.dump(config))
      yield path
    end
  end

  def test_supported_field_example_config_passes_validation
    stdout, stderr, status = run_cli(
      "validate",
      "--config",
      File.join(ROOT, "examples", "price-sentinel.example.yml")
    )

    assert status.success?, stderr
    assert_includes stdout, "Config valid"
    assert_includes stdout, "enabled checks: 1"
    assert_includes stdout, "enabled sources: 1"
  end

  def test_enabled_check_without_target_fails_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "missing-target",
          "enabled" => true,
          "product_name" => "Missing Target",
          "sources" => []
        }
      ]
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[missing-target].target.amount is required"
      assert_includes stderr, "checks[missing-target].target.currency is required"
    end
  end

  def test_incomplete_disabled_check_passes_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "draft-check",
          "enabled" => false
        }
      ]
    ) do |path|
      stdout, stderr, status = run_cli("validate", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "Config valid"
      assert_includes stdout, "enabled checks: 0"
      assert_includes stdout, "enabled sources: 0"
    end
  end

  def test_enabled_source_with_unknown_extractor_fails_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook",
          "enabled" => true,
          "product_name" => "MacBook",
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "sources" => [
            {
              "id" => "retailer",
              "enabled" => true,
              "extractor" => "unknown_extractor",
              "url" => "https://example.com/product"
            }
          ]
        }
      ]
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[macbook].sources[retailer].extractor is unknown: unknown_extractor"
    end
  end

  def test_enabled_source_with_malformed_url_fails_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook",
          "enabled" => true,
          "product_name" => "MacBook",
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "sources" => [
            {
              "id" => "retailer",
              "enabled" => true,
              "extractor" => "generic_product_page",
              "url" => "not a url"
            }
          ]
        }
      ]
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[macbook].sources[retailer].url must be an absolute http(s) URL"
    end
  end

  def test_enabled_source_with_unknown_price_unit_fails_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook",
          "enabled" => true,
          "product_name" => "MacBook",
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "sources" => [
            {
              "id" => "retailer",
              "enabled" => true,
              "extractor" => "generic_product_page",
              "url" => "https://example.com/macbook",
              "price_unit" => "cent"
            }
          ]
        }
      ]
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[macbook].sources[retailer].price_unit must be \"cents\" or \"dollars\": cent"
    end
  end

  def test_invalid_enabled_alert_transport_fails_validation
    with_config(
      "version" => 1,
      "alerts" => {
        "enabled" => true,
        "transports" => [
          {
            "id" => "personal-ntfy",
            "type" => "ntfy",
            "enabled" => true,
            "server" => "ntfy.sh"
          }
        ]
      },
      "checks" => []
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "alerts.transports[personal-ntfy].topic is required"
      assert_includes stderr, "alerts.transports[personal-ntfy].server must be an absolute http(s) URL"
    end
  end

  def test_parseable_but_structurally_invalid_config_fails_validation
    with_config("checks" => ["not-a-check"]) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[0] must be a mapping"
      refute_includes stderr, "NoMethodError"
    end
  end

  def test_enabled_check_without_enabled_sources_fails_validation
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "no-source",
          "enabled" => true,
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "sources" => []
        }
      ]
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "checks[no-source].sources must include at least one enabled source"
    end
  end

  def test_structurally_invalid_alert_transport_fails_validation
    with_config(
      "version" => 1,
      "alerts" => {
        "enabled" => true,
        "transports" => ["not-a-transport"]
      },
      "checks" => []
    ) do |path|
      _stdout, stderr, status = run_cli("validate", "--config", path)

      refute status.success?
      assert_includes stderr, "alerts.transports[0] must be a mapping"
      refute_includes stderr, "NoMethodError"
    end
  end
end
