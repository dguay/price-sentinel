# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../lib/price_sentinel/scanner"

class CliScanTest < Minitest::Test
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

  def scan_config(sources)
    {
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook-air",
          "enabled" => true,
          "product_name" => "MacBook Air",
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "required" => {
            "currency" => "CAD",
            "condition" => { "allow" => ["new"] },
            "seller" => { "allow" => ["Apple Canada"] },
            "availability" => { "allow" => ["in_stock"] },
            "ships_to" => "CA"
          },
          "attributes" => {
            "brand" => "Apple",
            "product_line" => "MacBook Air",
            "memory_gb" => 16,
            "storage_gb" => 512
          },
          "sources" => sources
        }
      ]
    }
  end

  def scan_config_with_log(sources, markdown_log:, run_id:, include_json: false)
    config = scan_config(sources).merge(
      "output" => {
        "markdown_log" => markdown_log,
        "include_json" => include_json
      }
    )
    config["run"] = { "run_id" => run_id } unless run_id.nil?
    config
  end

  def fake_source(id, fixture)
    {
      "id" => id,
      "enabled" => true,
      "extractor" => "fake_source",
      "url" => "https://example.com/#{id}",
      "fake_result" => fixture
    }
  end

  def test_scan_reports_target_price_hit_from_fake_found_source
    with_config(
      scan_config(
        [
          fake_source(
            "apple",
            {
              "state" => "found",
              "price" => { "amount" => 1699, "currency" => "CAD" },
              "observed" => {
                "condition" => "new",
                "seller" => "Apple Canada",
                "availability" => "in_stock",
                "ships_to" => "CA",
                "attributes" => {
                  "brand" => "Apple",
                  "product_line" => "MacBook Air",
                  "memory_gb" => 16,
                  "storage_gb" => 512
                }
              }
            }
          )
        ]
      )
    ) do |path|
      stdout, stderr, status = run_cli("scan", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "Scan complete: #{path}"
      assert_includes stdout, "checks scanned: 1"
      assert_includes stdout, "sources scanned: 1"
      assert_includes stdout, "target-price hits: 1"
      assert_includes stdout, "[found] macbook-air/apple CAD 1699.00 hit"
    end
  end

  def test_scan_classifies_all_fake_source_result_states
    with_config(
      scan_config(
        [
          fake_source(
            "found-source",
            {
              "state" => "found",
              "price" => { "amount" => 1899, "currency" => "CAD" },
              "observed" => {
                "condition" => "new",
                "seller" => "Apple Canada",
                "availability" => "in_stock",
                "ships_to" => "CA",
                "attributes" => {
                  "brand" => "Apple",
                  "product_line" => "MacBook Air",
                  "memory_gb" => 16,
                  "storage_gb" => 512
                }
              }
            }
          ),
          fake_source("no-match-source", { "state" => "no_match", "message" => "not the product" }),
          fake_source("uncertain-source", { "state" => "uncertain", "message" => "ambiguous title" }),
          fake_source("blocked-source", { "state" => "blocked", "message" => "access denied" }),
          fake_source("error-source", { "state" => "error", "message" => "parse failed" })
        ]
      )
    ) do |path|
      stdout, stderr, status = run_cli("scan", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "sources scanned: 5"
      assert_includes stdout, "target-price hits: 0"
      assert_includes stdout, "uncertain findings: 1"
      assert_includes stdout, "blocked sources: 1"
      assert_includes stdout, "errors: 1"
      assert_includes stdout, "[found] macbook-air/found-source CAD 1899.00"
      assert_includes stdout, "[no_match] macbook-air/no-match-source no price - not the product"
      assert_includes stdout, "[uncertain] macbook-air/uncertain-source no price - ambiguous title"
      assert_includes stdout, "[blocked] macbook-air/blocked-source no price - access denied"
      assert_includes stdout, "[error] macbook-air/error-source no price - parse failed"
    end
  end

  def test_target_price_hits_require_found_status_target_price_and_product_constraints
    matching_observation = lambda do
      {
        "condition" => "new",
        "seller" => "Apple Canada",
        "availability" => "in_stock",
        "ships_to" => "CA",
        "attributes" => {
          "brand" => "Apple",
          "product_line" => "MacBook Air",
          "memory_gb" => 16,
          "storage_gb" => 512
        }
      }
    end

    with_config(
      scan_config(
        [
          fake_source(
            "eligible",
            {
              "state" => "found",
              "price" => { "amount" => 1799, "currency" => "CAD" },
              "observed" => matching_observation.call
            }
          ),
          fake_source(
            "too-expensive",
            {
              "state" => "found",
              "price" => { "amount" => 1800, "currency" => "CAD" },
              "observed" => matching_observation.call
            }
          ),
          fake_source(
            "wrong-seller",
            {
              "state" => "found",
              "price" => { "amount" => 1299, "currency" => "CAD" },
              "observed" => matching_observation.call.merge("seller" => "Marketplace Seller")
            }
          ),
          fake_source(
            "wrong-condition",
            {
              "state" => "found",
              "price" => { "amount" => 1299, "currency" => "CAD" },
              "observed" => matching_observation.call.merge("condition" => "used")
            }
          ),
          fake_source(
            "uncertain-low-price",
            {
              "state" => "uncertain",
              "price" => { "amount" => 999, "currency" => "CAD" },
              "observed" => matching_observation.call,
              "message" => "price visible but identity unclear"
            }
          ),
          fake_source(
            "blocked-low-price",
            {
              "state" => "blocked",
              "price" => { "amount" => 999, "currency" => "CAD" },
              "observed" => matching_observation.call,
              "message" => "challenge page"
            }
          )
        ]
      )
    ) do |path|
      stdout, stderr, status = run_cli("scan", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "sources scanned: 6"
      assert_includes stdout, "target-price hits: 1"
      assert_includes stdout, "[found] macbook-air/eligible CAD 1799.00 hit"
      assert_includes stdout, "[found] macbook-air/too-expensive CAD 1800.00"
      assert_includes stdout, "[found] macbook-air/wrong-seller CAD 1299.00"
      assert_includes stdout, "[found] macbook-air/wrong-condition CAD 1299.00"
      assert_includes stdout, "[uncertain] macbook-air/uncertain-low-price CAD 999.00 - price visible but identity unclear"
      assert_includes stdout, "[blocked] macbook-air/blocked-low-price CAD 999.00 - challenge page"
      refute_includes stdout, "too-expensive CAD 1800.00 hit"
      refute_includes stdout, "wrong-seller CAD 1299.00 hit"
      refute_includes stdout, "wrong-condition CAD 1299.00 hit"
      refute_includes stdout, "uncertain-low-price CAD 999.00 hit"
      refute_includes stdout, "blocked-low-price CAD 999.00 hit"
    end
  end

  def test_target_price_hits_require_observed_product_attributes_to_match
    observation = {
      "condition" => "new",
      "seller" => "Apple Canada",
      "availability" => "in_stock",
      "ships_to" => "CA",
      "attributes" => {
        "brand" => "Apple",
        "product_line" => "MacBook Air",
        "memory_gb" => 16,
        "storage_gb" => 512
      }
    }

    with_config(
      scan_config(
        [
          fake_source(
            "matching-attributes",
            {
              "state" => "found",
              "price" => { "amount" => 1699, "currency" => "CAD" },
              "observed" => observation
            }
          ),
          fake_source(
            "wrong-storage",
            {
              "state" => "found",
              "price" => { "amount" => 999, "currency" => "CAD" },
              "observed" => observation.merge(
                "attributes" => observation.fetch("attributes").merge("storage_gb" => 256)
              )
            }
          )
        ]
      )
    ) do |path|
      stdout, stderr, status = run_cli("scan", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "target-price hits: 1"
      assert_includes stdout, "[found] macbook-air/matching-attributes CAD 1699.00 hit"
      assert_includes stdout, "[found] macbook-air/wrong-storage CAD 999.00"
      refute_includes stdout, "wrong-storage CAD 999.00 hit"
    end
  end

  def test_scan_prepends_scan_report_block_to_configured_markdown_log
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      File.write(log_path, "# Price Log\n\nOlder notes.\n")

      with_config(
        scan_config_with_log(
          [
            fake_source(
              "apple",
              {
                "state" => "found",
                "price" => { "amount" => 1699, "currency" => "CAD" },
                "observed" => {
                  "condition" => "new",
                  "seller" => "Apple Canada",
                  "availability" => "in_stock",
                  "ships_to" => "CA",
                  "attributes" => {
                    "brand" => "Apple",
                    "product_line" => "MacBook Air",
                    "memory_gb" => 16,
                    "storage_gb" => 512
                  }
                }
              }
            )
          ],
          markdown_log: log_path,
          run_id: "run-001"
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "Markdown log updated: #{log_path}"

        log = File.read(log_path)
        assert_match(/\A<!-- price-sentinel:scan-report run_id="run-001" -->/, log)
        assert_includes log, "## Price Sentinel Scan"
        assert_includes log, "Run ID: `run-001`"
        assert_includes log, "### Target-Price Hits"
        assert_includes log, "- `macbook-air/apple` - CAD 1699.00"
        assert_includes log, "# Price Log\n\nOlder notes."
      end
    end
  end

  def test_scan_replaces_existing_scan_report_block_for_same_run_id
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      config_path = File.join(dir, "active.yml")

      first_source = fake_source(
        "apple",
        {
          "state" => "found",
          "price" => { "amount" => 1699, "currency" => "CAD" },
          "observed" => {
            "condition" => "new",
            "seller" => "Apple Canada",
            "availability" => "in_stock",
            "ships_to" => "CA",
            "attributes" => {
              "brand" => "Apple",
              "product_line" => "MacBook Air",
              "memory_gb" => 16,
              "storage_gb" => 512
            }
          }
        }
      )
      second_source = fake_source(
        "apple",
        first_source.fetch("fake_result").merge("price" => { "amount" => 1599, "currency" => "CAD" })
      )

      File.write(config_path, YAML.dump(scan_config_with_log([first_source], markdown_log: log_path, run_id: "run-001")))
      _stdout, stderr, status = run_cli("scan", "--config", config_path)
      assert status.success?, stderr

      File.write(config_path, YAML.dump(scan_config_with_log([second_source], markdown_log: log_path, run_id: "run-001")))
      _stdout, stderr, status = run_cli("scan", "--config", config_path)
      assert status.success?, stderr

      log = File.read(log_path)
      assert_equal 1, log.scan('<!-- price-sentinel:scan-report run_id="run-001" -->').length
      assert_includes log, "CAD 1599.00"
      refute_includes log, "CAD 1699.00"
    end
  end

  def test_scan_with_different_run_id_prepends_above_older_runs
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      config_path = File.join(dir, "active.yml")
      source = fake_source("apple", { "state" => "no_match", "message" => "not listed" })

      File.write(config_path, YAML.dump(scan_config_with_log([source], markdown_log: log_path, run_id: "run-001")))
      _stdout, stderr, status = run_cli("scan", "--config", config_path)
      assert status.success?, stderr

      File.write(config_path, YAML.dump(scan_config_with_log([source], markdown_log: log_path, run_id: "run-002")))
      _stdout, stderr, status = run_cli("scan", "--config", config_path)
      assert status.success?, stderr

      log = File.read(log_path)
      assert_operator log.index('run_id="run-002"'), :<, log.index('run_id="run-001"')
    end
  end

  def test_scan_without_configured_run_id_keeps_back_to_back_scans_distinct
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      config_path = File.join(dir, "active.yml")
      source = fake_source("apple", { "state" => "no_match", "message" => "not listed" })
      File.write(config_path, YAML.dump(scan_config_with_log([source], markdown_log: log_path, run_id: nil)))

      2.times do
        _stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
      end

      log = File.read(log_path)
      assert_equal 2, log.scan("<!-- price-sentinel:scan-report run_id=").length
      refute_equal log.scan(/run_id="([^"]+)"/).first, log.scan(/run_id="([^"]+)"/).last
    end
  end

  def test_generated_run_ids_are_unique_for_back_to_back_scan_reports
    with_config(scan_config([fake_source("apple", { "state" => "no_match", "message" => "not listed" })])) do |path|
      run_ids = 20.times.map { PriceSentinel::Scanner.scan_file(path).run_id }

      assert_equal run_ids.length, run_ids.uniq.length
    end
  end

  def test_scan_report_block_groups_results_and_can_include_embedded_json
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      matching_observation = {
        "condition" => "new",
        "seller" => "Apple Canada",
        "availability" => "in_stock",
        "ships_to" => "CA",
        "attributes" => {
          "brand" => "Apple",
          "product_line" => "MacBook Air",
          "memory_gb" => 16,
          "storage_gb" => 512
        }
      }

      with_config(
        scan_config_with_log(
          [
            fake_source(
              "hit-source",
              {
                "state" => "found",
                "price" => { "amount" => 1699, "currency" => "CAD" },
                "observed" => matching_observation
              }
            ),
            fake_source("uncertain-source", { "state" => "uncertain", "message" => "ambiguous title" }),
            fake_source("blocked-source", { "state" => "blocked", "message" => "access denied" }),
            fake_source("error-source", { "state" => "error", "message" => "parse failed" })
          ],
          markdown_log: log_path,
          run_id: "run-001",
          include_json: true
        )
      ) do |path|
        _stdout, stderr, status = run_cli("scan", "--config", path)
        assert status.success?, stderr

        log = File.read(log_path)
        assert_includes log, "### Target-Price Hits"
        assert_includes log, "- `macbook-air/hit-source` - CAD 1699.00"
        assert_includes log, "### Uncertain Findings"
        assert_includes log, "- `macbook-air/uncertain-source` - no price - ambiguous title"
        assert_includes log, "### Blocked Sources"
        assert_includes log, "- `macbook-air/blocked-source` - no price - access denied"
        assert_includes log, "### Errors"
        assert_includes log, "- `macbook-air/error-source` - no price - parse failed"
        assert_match(/```json\n\{.*"run_id":"run-001".*"target_price_hits":1.*\}\n```/m, log)
      end
    end
  end
end
