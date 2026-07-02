# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class CliInitConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "price-sentinel")

  def run_cli(*args)
    Open3.capture3(CLI, *args)
  end

  def test_init_config_creates_generic_active_config_that_validates
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")

      stdout, stderr, status = run_cli(
        "init-config",
        "--template",
        "generic-product",
        "--config",
        config_path
      )

      assert status.success?, stderr
      assert File.exist?(config_path), "expected init-config to create #{config_path}"
      assert_includes stdout, "Created active config: #{config_path}"
      assert_includes stdout, "Scheduling is external to the CLI"
      assert_includes stdout, "Codex automation"
      assert_includes stdout, "Claude Code scheduled tasks"
      assert_includes stdout, "cron"
      assert_includes stdout, "launchd"
      assert_includes stdout, "examples/price-sentinel.example.yml"

      validate_stdout, validate_stderr, validate_status = run_cli("validate", "--config", config_path)

      assert validate_status.success?, validate_stderr
      assert_includes validate_stdout, "Config valid"
      assert_includes validate_stdout, "enabled checks: 1"
      assert_includes validate_stdout, "enabled sources: 1"
    end
  end

  def test_init_config_creates_macbook_canada_config_with_apple_canada_source
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "macbook.yml")

      stdout, stderr, status = run_cli(
        "init-config",
        "--template",
        "macbook-canada",
        "--config",
        config_path
      )

      assert status.success?, stderr
      assert_includes stdout, "Created active config: #{config_path}"

      config = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
      sources = config.fetch("checks").fetch(0).fetch("sources")
      source = sources.fetch(0)

      assert_equal "apple-ca-product-page", source.fetch("id")
      assert_equal "apple_ca", source.fetch("retailer")
      assert_equal "apple_ca_product_page", source.fetch("extractor")
      assert_match %r{\Ahttps://www\.apple\.com/ca/shop/buy-mac/macbook-air}, source.fetch("url")

      refurbished_source = sources.fetch(1)
      assert_equal "apple-ca-refurbished-mac", refurbished_source.fetch("id")
      assert_equal "apple_ca", refurbished_source.fetch("retailer")
      assert_equal "apple_ca_product_page", refurbished_source.fetch("extractor")
      assert_equal "https://www.apple.com/ca/shop/refurbished/mac", refurbished_source.fetch("url")

      validate_stdout, validate_stderr, validate_status = run_cli("validate", "--config", config_path)

      assert validate_status.success?, validate_stderr
      assert_includes validate_stdout, "enabled checks: 1"
      assert_includes validate_stdout, "enabled sources: 2"
    end
  end
end
