# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "time"
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

  def matching_observation
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

  def hit_source(id, amount: 1699)
    fake_source(
      id,
      {
        "state" => "found",
        "price" => { "amount" => amount, "currency" => "CAD" },
        "observed" => matching_observation
      }
    )
  end

  def search_result_config(source, target: 1500, target_currency: "CAD", condition_allow: ["used"])
    {
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook-air-search",
          "enabled" => true,
          "product_name" => "MacBook Air",
          "target" => { "amount" => target, "currency" => target_currency },
          "required" => {
            "currency" => target_currency,
            "condition" => { "allow" => condition_allow },
            "availability" => { "allow" => ["in_stock"] },
            "ships_to" => "CA"
          },
          "attributes" => {
            "brand" => "Apple",
            "product_line" => "MacBook Air",
            "model" => "13-inch",
            "chip" => "M4",
            "memory_gb" => 24,
            "storage_gb" => 512
          },
          "sources" => [source]
        }
      ]
    }
  end

  def with_ntfy_server
    requests = []
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets&.chomp
        headers = {}
        while (line = client.gets)
          line = line.chomp
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.strip
        end
        body = headers["content-length"].to_i.positive? ? client.read(headers["content-length"].to_i) : ""
        requests << { "request_line" => request_line, "headers" => headers, "body" => body }
        client.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        client.close
      end
    rescue IOError, Errno::EBADF
      # Server closed by the test.
    end

    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    server&.close
    thread&.join(2)
  end

  def with_product_page(body)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        client.gets
        while (line = client.gets)
          break if line.chomp.empty?
        end
        client.write "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        client.close
      end
    rescue IOError, Errno::EBADF
      # Server closed by the test.
    end

    yield "http://127.0.0.1:#{server.addr[1]}/product"
  ensure
    server&.close
    thread&.join(2)
  end

  def with_product_page_response(status:, reason:, body:)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        client.gets
        while (line = client.gets)
          break if line.chomp.empty?
        end
        client.write "HTTP/1.1 #{status} #{reason}\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        client.close
      end
    rescue IOError, Errno::EBADF
      # Server closed by the test.
    end

    yield "http://127.0.0.1:#{server.addr[1]}/product"
  ensure
    server&.close
    thread&.join(2)
  end

  def with_firecrawl_server(response_body)
    requests = []
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets&.chomp
        headers = {}
        while (line = client.gets)
          line = line.chomp
          break if line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.strip
        end
        body = headers["content-length"].to_i.positive? ? client.read(headers["content-length"].to_i) : ""
        requests << { "request_line" => request_line, "headers" => headers, "body" => body }
        client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
        client.close
      end
    rescue IOError, Errno::EBADF
      # Server closed by the test.
    end

    yield "http://127.0.0.1:#{server.addr[1]}/v2/scrape", requests
  ensure
    server&.close
    thread&.join(2)
  end

  def restore_env(name, value)
    if value.nil?
      ENV.delete(name)
    else
      ENV[name] = value
    end
  end

  def notification_config(
    sources,
    server:,
    topic: "price-sentinel-test-long-random-topic",
    notify_on: nil,
    dedupe: nil,
    message_template: "{{check.id}}/{{source.id}} is {{price.currency}} {{price.amount}}"
  )
    alerts = {
      "enabled" => true,
      "transports" => [
        {
          "id" => "local-ntfy",
          "type" => "ntfy",
          "enabled" => true,
          "server" => server,
          "topic" => topic,
          "priority" => "high",
          "tags" => ["shopping_cart", "price-tag"],
          "title_template" => "Price hit: {{check.product_name}}",
          "message_template" => message_template,
          "click" => "https://example.com/deal",
          "token_env" => "PRICE_SENTINEL_TEST_NTFY_TOKEN"
        }
      ]
    }
    alerts["notify_on"] = notify_on unless notify_on.nil?
    alerts["dedupe"] = dedupe unless dedupe.nil?

    scan_config(sources).merge(
      "alerts" => alerts,
      "run" => { "run_id" => "run-ntfy" }
    )
  end

  def default_lock_path(config_path, state_dir: nil)
    state_dir ||= File.join(File.dirname(config_path), ".price-sentinel")
    digest = Digest::SHA256.hexdigest(File.expand_path(config_path))[0, 12]
    File.join(state_dir, "scan-#{File.basename(config_path)}-#{digest}.lock")
  end

  def test_scan_sends_ntfy_notification_for_first_target_price_hit
    with_ntfy_server do |server, requests|
      original_token = ENV["PRICE_SENTINEL_TEST_NTFY_TOKEN"]
      ENV["PRICE_SENTINEL_TEST_NTFY_TOKEN"] = "test-token"

      with_config(notification_config([hit_source("apple")], server: server)) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"

        assert_equal 1, requests.length
        request = requests.fetch(0)
        assert_equal "POST /price-sentinel-test-long-random-topic HTTP/1.1", request.fetch("request_line")
        assert_equal "Price hit: MacBook Air", request.dig("headers", "title")
        assert_equal "high", request.dig("headers", "priority")
        assert_equal "shopping_cart,price-tag", request.dig("headers", "tags")
        assert_equal "https://example.com/deal", request.dig("headers", "click")
        assert_equal "Bearer test-token", request.dig("headers", "authorization")
        assert_equal "macbook-air/apple is CAD 1699", request.fetch("body")
      end
    ensure
      ENV["PRICE_SENTINEL_TEST_NTFY_TOKEN"] = original_token
    end
  end

  def test_scan_extracts_json_ld_product_page_from_configured_source
    page = <<~HTML
      <!doctype html>
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Product",
              "name": "MacBook Air",
              "description": "Apple MacBook Air.",
              "offers": {
                "@type": "AggregateOffer",
                "lowPrice": "1699.00",
                "priceCurrency": "CAD",
                "url": "http://example.com/macbook-air"
              }
            }
          </script>
        </head>
        <body>MacBook Air – 15-inch – M5 Chip – 16GB memory – 512GB storage</body>
      </html>
    HTML
    page = page.b

    with_product_page(page) do |url|
      with_config(
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
              "ships_to" => "CA"
            },
            "attributes" => {
              "category" => "laptop",
              "brand" => "Apple",
              "product_line" => "MacBook Air",
              "chip" => "M5"
            },
            "sources" => [
              {
                "id" => "apple",
                "enabled" => true,
                "retailer" => "apple_ca",
                "extractor" => "apple_ca_product_page",
                "url" => url,
                "expected_country" => "CA"
              }
            ]
          }
        ]
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air/apple CAD 1699.00 hit"
        refute_includes stdout, "extractor is not implemented"
      end
    end
  end

  def test_scan_extracts_server_rendered_search_result_matching_expected_attributes
    page = <<~HTML
      <!doctype html>
      <html>
        <body>
          <div class="product-item">
            <h2 class="product-item__title_list">
              <a href="/configure-my-mac/apple-macbook-air-m4-series-13-inch">
                Apple 13" MacBook Air Retina (2025) 10-core Apple M4, 24GB unified memory, 512GB SSD - Used, Premium condition
              </a>
            </h2>
            <div class="product-item__pricing_large">Only <div>$1,169.00</div></div>
            <a>Add to Cart</a>
          </div>
        </body>
      </html>
    HTML

    with_product_page(page) do |url|
      source = {
        "id" => "owc-search",
        "enabled" => true,
        "retailer" => "owc_macsales",
        "extractor" => "generic_product_page",
        "url" => url,
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, target_currency: "USD")) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air-search/owc-search USD 1169.00 hit"

        report = PriceSentinel::Scanner.scan_file(path)
        assert_equal URI.join(url, "/configure-my-mac/apple-macbook-air-m4-series-13-inch").to_s,
          report.results.first.product_url
      end
    end
  end

  def test_scan_extracts_shopify_embedded_search_result_matching_expected_attributes
    page = <<~HTML
      <!doctype html>
      <html>
        <body>
          <script>
            {id:9438554489071,handle:"macbook-air-13-m4-10c-cpu-10c-gpu-24gb-512gb-midnight-open-box",title:"MacBook Air 13\\" M4 (10c CPU \\/ 10c GPU, 24GB, 512GB, Midnight) - Open Box",variants:[{id:49970518655215,title:"Default Title",inventory_quantity:1,inventory_management:"shopify",inventory_policy:"deny",price:139900,compare_at_price:0,selling_plan_allocations: []}]};
          </script>
        </body>
      </html>
    HTML

    with_product_page(page) do |url|
      source = {
        "id" => "jumpplus-search",
        "enabled" => true,
        "retailer" => "jumpplus",
        "extractor" => "generic_product_page",
        "url" => url,
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["open_box"])) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air-search/jumpplus-search CAD 1399.00 hit"

        report = PriceSentinel::Scanner.scan_file(path)
        assert_equal URI.join(url, "/products/macbook-air-13-m4-10c-cpu-10c-gpu-24gb-512gb-midnight-open-box").to_s,
          report.results.first.product_url
      end
    end
  end

  def test_scan_does_not_match_shopify_embedded_fee_objects_using_page_level_attributes
    page = <<~HTML
      <!doctype html>
      <html>
        <head>
          <title>Search: results found for MacBook Air M4 13 24GB 512GB</title>
        </head>
        <body>
          <h1>Search results for MacBook Air M4 13 24GB 512GB</h1>
          <script>
            {id:1,handle:"computer-peripherals-ca",title:"Computer Peripherals - CA",variants:[{id:2,title:"Default Title",inventory_quantity:1,inventory_management:"shopify",inventory_policy:"deny",price:0,compare_at_price:0,selling_plan_allocations: []}]};
            {id:9438554489071,handle:"macbook-air-13-m4-10c-cpu-10c-gpu-16gb-512gb-midnight-open-box",title:"MacBook Air 13\\" M4 (10c CPU \\/ 10c GPU, 16GB, 512GB, Midnight) - Open Box",variants:[{id:49970518655215,title:"Default Title",inventory_quantity:1,inventory_management:"shopify",inventory_policy:"deny",price:139900,compare_at_price:0,selling_plan_allocations: []}]};
          </script>
        </body>
      </html>
    HTML

    with_product_page(page) do |url|
      source = {
        "id" => "jumpplus-search",
        "enabled" => true,
        "retailer" => "jumpplus",
        "extractor" => "generic_product_page",
        "url" => url,
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["open_box"])) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[no_match] macbook-air-search/jumpplus-search no price - matching product was not found"
      end
    end
  end

  def test_scan_reports_no_match_when_search_results_do_not_match_expected_attributes
    page = <<~HTML
      <!doctype html>
      <html>
        <body>
          <div class="search-result">
            <h2>
              <a class="search-result-product-url">UAG Essential Armor MacBook Air 13" (M5/M4/M3/M2) Case - Ice</a>
            </h2>
            <div class="price-type-price" aria-label="Discounted price" role="note">$61.99</div>
            <button>Add To Cart</button>
          </div>
        </body>
      </html>
    HTML

    with_product_page(page) do |url|
      source = {
        "id" => "cdw-search",
        "enabled" => true,
        "retailer" => "cdw_ca",
        "extractor" => "generic_product_page",
        "url" => url,
        "expected_country" => "CA"
      }

      with_config(search_result_config(source)) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[no_match] macbook-air-search/cdw-search no price - matching product was not found"
      end
    end
  end

  def test_scan_reports_no_match_for_explicit_zero_result_search_page
    page = <<~HTML
      <!doctype html>
      <html>
        <head><title>MacBook Air M4 13 24GB 512GB | Newegg.ca</title></head>
        <body>
          <script>
            window.__initialState__ = {"Products":null,"TotalItemCount":0};
          </script>
        </body>
      </html>
    HTML

    with_product_page(page) do |url|
      source = {
        "id" => "newegg-search",
        "enabled" => true,
        "retailer" => "newegg_ca",
        "extractor" => "generic_product_page",
        "url" => url,
        "expected_country" => "CA"
      }

      with_config(search_result_config(source)) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[no_match] macbook-air-search/newegg-search no price - matching product was not found"
      end
    end
  end

  def test_scan_treats_amazon_503_something_went_wrong_as_blocked
    page = <<~HTML
      <!doctype html>
      <html>
        <head><title>Amazon.ca Something Went Wrong / Quelque chose s'est mal passe</title></head>
        <body>Sorry! Something went wrong. Please go back and try again.</body>
      </html>
    HTML

    with_product_page_response(status: 503, reason: "Service Unavailable", body: page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "amazon-search",
              "enabled" => true,
              "retailer" => "amazon_ca",
              "extractor" => "generic_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "blocked sources: 1"
        assert_includes stdout, "[blocked] macbook-air/amazon-search no price - source returned HTTP 503 access barrier"
      end
    end
  end

  def test_scan_extracts_firecrawl_amazon_search_json_result_matching_expected_attributes
    firecrawl_response = JSON.generate(
      "success" => true,
      "data" => {
        "metadata" => {
          "statusCode" => 200,
          "title" => "Amazon.ca : MacBook Air M4 13 24GB 512GB"
        },
        "json" => {
          "products" => [
            {
              "title" => "Apple 2025 MacBook Air 13-inch Laptop with M4 chip: Built for Apple Intelligence, 24GB Unified Memory, 512GB SSD Storage, Touch ID; Sky Blue - English Keyboard",
              "url" => "https://www.amazon.ca/Apple-2025-MacBook-13-inch-Laptop/dp/B0DZF3X94N",
              "price_amount" => 1399.99,
              "currency" => "CAD",
              "availability" => "In stock.",
              "sponsored" => false
            }
          ]
        }
      }
    )

    with_firecrawl_server(firecrawl_response) do |server, requests|
      original_key = ENV["FIRECRAWL_API_KEY"]
      original_url = ENV["FIRECRAWL_API_URL"]
      ENV["FIRECRAWL_API_KEY"] = "test-firecrawl-token"
      ENV["FIRECRAWL_API_URL"] = server

      source = {
        "id" => "amazon-search",
        "enabled" => true,
        "retailer" => "amazon_ca",
        "extractor" => "firecrawl_amazon_search",
        "url" => "https://www.amazon.ca/s?k=MacBook+Air+M4+13+24GB+512GB",
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["new"])) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air-search/amazon-search CAD 1399.99 hit"

        assert_equal 1, requests.length
        request = requests.fetch(0)
        assert_equal "POST /v2/scrape HTTP/1.1", request.fetch("request_line")
        assert_equal "Bearer test-firecrawl-token", request.dig("headers", "authorization")
        body = JSON.parse(request.fetch("body"))
        assert_equal source.fetch("url"), body.fetch("url")
        prompt = body.fetch("formats").fetch(0).fetch("prompt")
        assert_includes prompt, "MacBook Air"
        refute_includes prompt, "Apple MacBook Air listings"
      end
    ensure
      restore_env("FIRECRAWL_API_KEY", original_key)
      restore_env("FIRECRAWL_API_URL", original_url)
    end
  end

  def test_scan_loads_firecrawl_api_key_from_dotenv_file
    firecrawl_response = JSON.generate(
      "success" => true,
      "data" => {
        "metadata" => { "statusCode" => 200 },
        "json" => {
          "products" => [
            {
              "title" => "Apple 2025 MacBook Air 13-inch Laptop with M4 chip, 24GB Unified Memory, 512GB SSD Storage",
              "url" => "https://www.amazon.ca/dp/example",
              "price_amount" => 1399.99,
              "currency" => "CAD",
              "availability" => "In stock."
            }
          ]
        }
      }
    )

    with_firecrawl_server(firecrawl_response) do |server, requests|
      Dir.mktmpdir do |dir|
        original_key = ENV["FIRECRAWL_API_KEY"]
        original_url = ENV["FIRECRAWL_API_URL"]
        ENV.delete("FIRECRAWL_API_KEY")
        ENV["FIRECRAWL_API_URL"] = server
        File.write(File.join(dir, ".env"), "FIRECRAWL_API_KEY=dotenv-firecrawl-token\n")

        source = {
          "id" => "amazon-search",
          "enabled" => true,
          "retailer" => "amazon_ca",
          "extractor" => "firecrawl_amazon_search",
          "url" => "https://www.amazon.ca/s?k=MacBook+Air+M4+13+24GB+512GB",
          "expected_country" => "CA"
        }

        with_config(search_result_config(source, condition_allow: ["new"])) do |path|
          stdout, stderr, status = Open3.capture3(CLI, "scan", "--config", path, chdir: dir)

          assert status.success?, stderr
          assert_includes stdout, "[found] macbook-air-search/amazon-search CAD 1399.99 hit"
          assert_equal "Bearer dotenv-firecrawl-token", requests.fetch(0).dig("headers", "authorization")
        end
      ensure
        restore_env("FIRECRAWL_API_KEY", original_key)
        restore_env("FIRECRAWL_API_URL", original_url)
      end
    end
  end

  def test_scan_reports_firecrawl_amazon_access_barrier_as_blocked
    firecrawl_response = JSON.generate(
      "success" => true,
      "data" => {
        "metadata" => {
          "statusCode" => 503,
          "title" => "Amazon.ca Something Went Wrong / Quelque chose s'est mal passe"
        },
        "json" => { "products" => [] }
      }
    )

    with_firecrawl_server(firecrawl_response) do |server, _requests|
      original_key = ENV["FIRECRAWL_API_KEY"]
      original_url = ENV["FIRECRAWL_API_URL"]
      ENV["FIRECRAWL_API_KEY"] = "test-firecrawl-token"
      ENV["FIRECRAWL_API_URL"] = server

      source = {
        "id" => "amazon-search",
        "enabled" => true,
        "retailer" => "amazon_ca",
        "extractor" => "firecrawl_amazon_search",
        "url" => "https://www.amazon.ca/s?k=MacBook+Air+M4+13+24GB+512GB",
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["new"])) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "blocked sources: 1"
        assert_includes stdout, "[blocked] macbook-air-search/amazon-search no price - Firecrawl page returned HTTP 503 access barrier"
      end
    ensure
      restore_env("FIRECRAWL_API_KEY", original_key)
      restore_env("FIRECRAWL_API_URL", original_url)
    end
  end

  def test_scan_reports_error_when_firecrawl_api_key_is_missing
    Dir.mktmpdir do |dir|
      original_key = ENV["FIRECRAWL_API_KEY"]
      original_url = ENV["FIRECRAWL_API_URL"]
      ENV.delete("FIRECRAWL_API_KEY")
      ENV.delete("FIRECRAWL_API_URL")

      source = {
        "id" => "amazon-search",
        "enabled" => true,
        "retailer" => "amazon_ca",
        "extractor" => "firecrawl_amazon_search",
        "url" => "https://www.amazon.ca/s?k=MacBook+Air+M4+13+24GB+512GB",
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["new"])) do |path|
        stdout, stderr, status = Open3.capture3(CLI, "scan", "--config", path, chdir: dir)

        assert status.success?, stderr
        assert_includes stdout, "errors: 1"
        assert_includes stdout, "[error] macbook-air-search/amazon-search no price - FIRECRAWL_API_KEY is required"
      end
    ensure
      restore_env("FIRECRAWL_API_KEY", original_key)
      restore_env("FIRECRAWL_API_URL", original_url)
    end
  end

  def test_scan_reports_no_match_when_firecrawl_products_do_not_match_expected_attributes
    firecrawl_response = JSON.generate(
      "success" => true,
      "data" => {
        "metadata" => { "statusCode" => 200 },
        "json" => {
          "products" => [
            {
              "title" => "Apple iPad Air 13-inch with M4 chip, 256GB storage",
              "url" => "https://www.amazon.ca/dp/ipad-example",
              "price_amount" => 999.99,
              "currency" => "CAD",
              "availability" => "In stock."
            }
          ]
        }
      }
    )

    with_firecrawl_server(firecrawl_response) do |server, _requests|
      original_key = ENV["FIRECRAWL_API_KEY"]
      original_url = ENV["FIRECRAWL_API_URL"]
      ENV["FIRECRAWL_API_KEY"] = "test-firecrawl-token"
      ENV["FIRECRAWL_API_URL"] = server

      source = {
        "id" => "amazon-search",
        "enabled" => true,
        "retailer" => "amazon_ca",
        "extractor" => "firecrawl_amazon_search",
        "url" => "https://www.amazon.ca/s?k=MacBook+Air+M4+13+24GB+512GB",
        "expected_country" => "CA"
      }

      with_config(search_result_config(source, condition_allow: ["new"])) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[no_match] macbook-air-search/amazon-search no price - matching product was not found"
      end
    ensure
      restore_env("FIRECRAWL_API_KEY", original_key)
      restore_env("FIRECRAWL_API_URL", original_url)
    end
  end

  def test_scan_extracts_apple_canada_product_page_fixture_through_normal_scan_path
    page = File.binread(File.join(ROOT, "test", "fixtures", "apple_ca_macbook_air_product.html"))

    with_product_page(page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-product-page",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air/apple-product-page CAD 1699.00 hit"
      end
    end
  end

  def test_scan_does_not_block_valid_apple_page_with_harmless_akamai_asset
    product_page = File.binread(File.join(ROOT, "test", "fixtures", "apple_ca_macbook_air_product.html"))
    page = product_page.sub("</head>", %(<script src="https://www.apple.com/akamai/rum.js"></script>\n</head>))

    with_product_page(page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-product-page",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] macbook-air/apple-product-page CAD 1699.00 hit"
        refute_includes stdout, "[blocked] macbook-air/apple-product-page"
      end
    end
  end

  def test_scan_extracts_apple_canada_refurbished_page_fixture_through_normal_scan_path
    page = File.binread(File.join(ROOT, "test", "fixtures", "apple_ca_refurbished_mac.html"))

    with_product_page(page) do |url|
      with_config(
        {
          "version" => 1,
          "alerts" => { "enabled" => false },
          "checks" => [
            {
              "id" => "refurb-macbook-air",
              "enabled" => true,
              "product_name" => "Refurbished MacBook Air",
              "target" => { "amount" => 1299, "currency" => "CAD" },
              "required" => {
                "currency" => "CAD",
                "condition" => { "allow" => ["refurbished"] },
                "seller" => { "allow" => ["Apple Canada"] },
                "availability" => { "allow" => ["in_stock"] },
                "ships_to" => "CA"
              },
              "attributes" => {
                "brand" => "Apple",
                "product_line" => "MacBook Air",
                "chip" => "M4",
                "memory_gb" => 16,
                "storage_gb" => 512
              },
              "sources" => [
                {
                  "id" => "apple-refurbished-mac",
                  "enabled" => true,
                  "retailer" => "apple_ca",
                  "extractor" => "apple_ca_product_page",
                  "url" => url,
                  "expected_country" => "CA"
                }
              ]
            }
          ]
        }
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 1"
        assert_includes stdout, "[found] refurb-macbook-air/apple-refurbished-mac CAD 1199.00 hit"
      end
    end
  end

  def test_scan_does_not_classify_refurbished_apple_json_candidate_as_new
    page = <<~HTML
      <!doctype html>
      <html>
        <head>
          <script type="application/json">
            {
              "products": [
                {
                  "title": "Refurbished 13-inch MacBook Air Apple M4 Chip",
                  "specs": "16GB unified memory, 512GB SSD storage",
                  "priceData": {
                    "currentPrice": {
                      "amount": "1199.00",
                      "currency": "CAD"
                    }
                  },
                  "availability": "In Stock"
                }
              ]
            }
          </script>
        </head>
      </html>
    HTML

    with_product_page(page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-refurbished-json",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[found] macbook-air/apple-refurbished-json CAD 1199.00"
        refute_includes stdout, "apple-refurbished-json CAD 1199.00 hit"
      end
    end
  end

  def test_scan_does_not_count_unavailable_apple_product_as_target_price_hit
    page = <<~HTML
      <!doctype html>
      <html>
        <head>
          <script type="application/json">
            {
              "products": [
                {
                  "title": "MacBook Air 15-inch",
                  "specs": "Apple M4 chip, 16GB unified memory, 512GB SSD storage",
                  "priceData": {
                    "currentPrice": {
                      "amount": "1199.00",
                      "currency": "CAD"
                    }
                  },
                  "availability": "Not In Stock"
                }
              ]
            }
          </script>
        </head>
      </html>
    HTML

    with_product_page(page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-unavailable",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "target-price hits: 0"
        assert_includes stdout, "[found] macbook-air/apple-unavailable CAD 1199.00"
        refute_includes stdout, "apple-unavailable CAD 1199.00 hit"
      end
    end
  end

  def test_scan_reports_apple_canada_access_denial_as_blocked
    with_product_page_response(status: 403, reason: "Forbidden", body: "Forbidden") do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-product-page",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "blocked sources: 1"
        assert_includes stdout, "[blocked] macbook-air/apple-product-page no price - source returned HTTP 403"
      end
    end
  end

  def test_scan_reports_apple_canada_challenge_page_as_blocked
    page = <<~HTML
      <!doctype html>
      <html>
        <head><title>Access Denied</title></head>
        <body>
          <h1>Access Denied</h1>
          <p>Please verify you are human before continuing.</p>
        </body>
      </html>
    HTML

    with_product_page_response(status: 200, reason: "OK", body: page) do |url|
      with_config(
        scan_config(
          [
            {
              "id" => "apple-challenge-page",
              "enabled" => true,
              "retailer" => "apple_ca",
              "extractor" => "apple_ca_product_page",
              "url" => url,
              "expected_country" => "CA"
            }
          ]
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "blocked sources: 1"
        assert_includes stdout, "[blocked] macbook-air/apple-challenge-page no price - source returned an access-denied or challenge page"
      end
    end
  end

  def test_scan_ignores_sources_listed_only_in_starter_template_metadata
    with_config(
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [],
      "templates" => {
        "available" => [
          {
            "name" => "example-template",
            "checks" => [
              {
                "id" => "template-only-check",
                "enabled" => true,
                "target" => { "amount" => 10, "currency" => "CAD" },
                "sources" => [
                  fake_source("template-only-source", { "state" => "found" })
                ]
              }
            ]
          }
        ]
      }
    ) do |path|
      stdout, stderr, status = run_cli("scan", "--config", path)

      assert status.success?, stderr
      assert_includes stdout, "checks scanned: 0"
      assert_includes stdout, "sources scanned: 0"
      refute_includes stdout, "template-only-check/template-only-source"
    end
  end

  def test_scan_suppresses_unchanged_repeated_hit_notification
    with_ntfy_server do |server, requests|
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "active.yml")
        File.write(config_path, YAML.dump(notification_config([hit_source("apple")], server: server)))

        stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"

        stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 0"

        assert_equal 1, requests.length
        state = JSON.parse(File.read(File.join(dir, ".price-sentinel", "alert-state.json")))
        assert_equal true, state.dig("sources", "macbook-air/apple", "hit")
        assert_equal({ "amount" => 1699, "currency" => "CAD" }, state.dig("sources", "macbook-air/apple", "price"))
      end
    end
  end

  def test_scan_notifies_again_when_hit_price_drops
    with_ntfy_server do |server, requests|
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "active.yml")
        File.write(config_path, YAML.dump(notification_config([hit_source("apple", amount: 1699)], server: server)))
        _stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr

        File.write(config_path, YAML.dump(notification_config([hit_source("apple", amount: 1599)], server: server)))
        stdout, stderr, status = run_cli("scan", "--config", config_path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"
        assert_equal 2, requests.length
        assert_equal "macbook-air/apple is CAD 1599", requests.last.fetch("body")
      end
    end
  end

  def test_scan_notifies_when_source_reenters_hit_state
    with_ntfy_server do |server, requests|
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "active.yml")
        File.write(config_path, YAML.dump(notification_config([hit_source("apple", amount: 1699)], server: server)))
        _stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr

        File.write(
          config_path,
          YAML.dump(notification_config([fake_source("apple", { "state" => "no_match", "message" => "not listed" })], server: server))
        )
        stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 0"

        File.write(config_path, YAML.dump(notification_config([hit_source("apple", amount: 1699)], server: server)))
        stdout, stderr, status = run_cli("scan", "--config", config_path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"
        assert_equal 2, requests.length
        assert_equal "macbook-air/apple is CAD 1699", requests.last.fetch("body")
      end
    end
  end

  def test_scan_treats_first_hit_after_prior_non_hit_as_first_hit
    with_ntfy_server do |server, requests|
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "active.yml")
        first_hit_only = { "notify_when" => ["first_hit_for_check_source"] }
        File.write(
          config_path,
          YAML.dump(
            notification_config(
              [fake_source("apple", { "state" => "no_match", "message" => "not listed" })],
              server: server,
              dedupe: first_hit_only,
              message_template: "{{reason}} {{check.id}}/{{source.id}}"
            )
          )
        )
        stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 0"

        File.write(
          config_path,
          YAML.dump(
            notification_config(
              [hit_source("apple", amount: 1699)],
              server: server,
              dedupe: first_hit_only,
              message_template: "{{reason}} {{check.id}}/{{source.id}}"
            )
          )
        )
        stdout, stderr, status = run_cli("scan", "--config", config_path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"
        assert_equal 1, requests.length
        assert_equal "first_hit_for_check_source macbook-air/apple", requests.first.fetch("body")
      end
    end
  end

  def test_scan_does_not_advance_alert_state_without_enabled_ntfy_transport
    with_ntfy_server do |server, requests|
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "active.yml")
        config_without_transports = scan_config([hit_source("apple")]).merge(
          "alerts" => {
            "enabled" => true,
            "transports" => []
          },
          "run" => { "run_id" => "run-no-transport" }
        )
        File.write(config_path, YAML.dump(config_without_transports))

        stdout, stderr, status = run_cli("scan", "--config", config_path)
        assert status.success?, stderr
        refute_includes stdout, "Notification state updated:"
        refute File.exist?(File.join(dir, ".price-sentinel", "alert-state.json"))

        File.write(config_path, YAML.dump(notification_config([hit_source("apple")], server: server)))
        stdout, stderr, status = run_cli("scan", "--config", config_path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"
        assert_equal 1, requests.length
      end
    end
  end

  def test_scan_notification_policy_defaults_to_hits_and_errors_only
    with_ntfy_server do |server, requests|
      with_config(
        notification_config(
          [
            fake_source("uncertain-source", { "state" => "uncertain", "message" => "ambiguous title" }),
            fake_source("blocked-source", { "state" => "blocked", "message" => "access denied" }),
            fake_source("error-source", { "state" => "error", "message" => "parse failed" })
          ],
          server: server,
          message_template: "{{check.id}}/{{source.id}} {{result.state}} {{result.message}}"
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 1"
        assert_equal 1, requests.length
        assert_equal "macbook-air/error-source error parse failed", requests.first.fetch("body")
      end
    end
  end

  def test_scan_notification_policy_can_opt_into_uncertain_blocked_and_summary
    with_ntfy_server do |server, requests|
      with_config(
        notification_config(
          [
            fake_source("uncertain-source", { "state" => "uncertain", "message" => "ambiguous title" }),
            fake_source("blocked-source", { "state" => "blocked", "message" => "access denied" })
          ],
          server: server,
          notify_on: {
            "hits" => false,
            "errors" => false,
            "uncertain" => true,
            "blocked" => true,
            "scan_summary" => true
          },
          message_template: "{{category}} {{check.id}}/{{source.id}} {{result.message}} {{run_id}}"
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "Notifications sent: 3"
        assert_equal 3, requests.length
        assert_equal "uncertain macbook-air/uncertain-source ambiguous title run-ntfy", requests[0].fetch("body")
        assert_equal "blocked macbook-air/blocked-source access denied run-ntfy", requests[1].fetch("body")
        assert_equal "scan_summary /  run-ntfy", requests[2].fetch("body")
      end
    end
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
      refute_includes stdout, "Notifications sent:"
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

  def test_scan_creates_configured_markdown_log_when_file_does_not_exist
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      refute File.exist?(log_path)

      with_config(
        scan_config_with_log(
          [
            fake_source(
              "apple",
              {
                "state" => "no_match",
                "message" => "not listed"
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
        assert File.exist?(log_path), "expected scan to create configured Markdown log"

        log = File.read(log_path)
        assert_match(/\A<!-- price-sentinel:scan-report run_id="run-001" -->/, log)
        assert_includes log, "Run ID: `run-001`"
        assert_includes log, "- Sources scanned: 1"
      end
    end
  end

  def test_scan_reports_markdown_log_write_failure_without_stack_trace
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "price-log.md")
      Dir.mkdir(log_path)

      with_config(
        scan_config_with_log(
          [
            fake_source(
              "apple",
              {
                "state" => "no_match",
                "message" => "not listed"
              }
            )
          ],
          markdown_log: log_path,
          run_id: "run-001"
        )
      ) do |path|
        stdout, stderr, status = run_cli("scan", "--config", path)

        refute status.success?
        assert_includes stdout, "Scan complete: #{path}"
        refute_includes stdout, "Markdown log updated:"
        assert_includes stderr, "Markdown log update failed:"
        refute_includes stderr, "markdown_log.rb"
        refute File.exist?(File.join(File.dirname(path), ".price-sentinel", "last-scan.json"))
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
                "product_url" => "https://example.com/products/macbook-air",
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
        assert_includes log, "- `macbook-air/hit-source` - CAD 1699.00 - https://example.com/products/macbook-air"
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

  def test_scan_records_last_scan_state_in_default_directory_beside_active_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")
      File.write(
        config_path,
        YAML.dump(
          scan_config_with_log(
            [fake_source("apple", { "state" => "no_match", "message" => "not listed" })],
            markdown_log: "price-log.md",
            run_id: "run-001"
          )
        )
      )

      stdout, stderr, status = run_cli("scan", "--config", config_path)

      assert status.success?, stderr
      state_path = File.join(dir, ".price-sentinel", "last-scan.json")
      assert_includes stdout, "Monitor state updated: #{state_path}"

      state = JSON.parse(File.read(state_path))
      assert_equal "run-001", state.fetch("run_id")
      assert_equal config_path, state.fetch("config_path")
      assert_equal 1, state.fetch("sources_scanned")
      assert_equal 0, state.fetch("target_price_hits")
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, state.fetch("completed_at"))
      assert_empty Dir.glob(File.join(dir, ".price-sentinel", "*.lock"))
    end
  end

  def test_scan_records_last_scan_state_at_explicit_path
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "configs", "active.yml")
      override_path = File.join(dir, "state", "custom-last-scan.json")
      FileUtils.mkdir_p(File.dirname(config_path))
      config = scan_config(
        [fake_source("apple", { "state" => "no_match", "message" => "not listed" })]
      ).merge(
        "state" => { "last_scan_file" => override_path },
        "run" => { "run_id" => "run-override" }
      )
      File.write(config_path, YAML.dump(config))

      stdout, stderr, status = run_cli("scan", "--config", config_path)

      assert status.success?, stderr
      assert_includes stdout, "Monitor state updated: #{override_path}"
      assert_equal "run-override", JSON.parse(File.read(override_path)).fetch("run_id")
      refute File.exist?(File.join(File.dirname(config_path), ".price-sentinel", "last-scan.json"))
    end
  end

  def test_scan_refuses_when_lock_is_active_without_mutating_markdown_log
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")
      log_path = File.join(dir, "price-log.md")
      lock_path = default_lock_path(config_path)
      original_log = "# Price Log\n\nExisting entry.\n"
      File.write(log_path, original_log)
      File.write(
        config_path,
        YAML.dump(
          scan_config_with_log(
            [fake_source("apple", { "state" => "no_match", "message" => "not listed" })],
            markdown_log: log_path,
            run_id: "run-locked"
          )
        )
      )
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(
        lock_path,
        JSON.generate(
          "config_path" => config_path,
          "started_at" => Time.now.utc.iso8601,
          "pid" => Process.pid
        )
      )

      stdout, stderr, status = run_cli("scan", "--config", config_path)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "Scan already active for config: #{config_path}"
      assert_equal original_log, File.read(log_path)
      refute File.exist?(File.join(dir, ".price-sentinel", "last-scan.json"))
    end
  end

  def test_scan_refuses_while_another_process_holds_the_lock
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")
      log_path = File.join(dir, "price-log.md")
      lock_path = default_lock_path(config_path)
      original_log = "# Price Log\n\nExisting entry.\n"
      File.write(log_path, original_log)
      File.write(
        config_path,
        YAML.dump(
          scan_config_with_log(
            [fake_source("apple", { "state" => "no_match", "message" => "not listed" })],
            markdown_log: log_path,
            run_id: "run-live-lock"
          )
        )
      )
      FileUtils.mkdir_p(File.dirname(lock_path))

      locker = IO.popen(
        [
          RbConfig.ruby,
          "-rjson",
          "-rtime",
          "-e",
          "path, config_path = ARGV; file = File.open(path, File::RDWR | File::CREAT, 0644); " \
          "file.flock(File::LOCK_EX); " \
          "file.write(JSON.generate('config_path' => config_path, 'started_at' => Time.now.utc.iso8601, " \
          "'pid' => Process.pid, 'owner_token' => 'test-locker')); file.flush; " \
          "puts 'locked'; STDOUT.flush; sleep",
          lock_path,
          config_path
        ],
        "r"
      )
      assert_equal "locked\n", locker.gets

      stdout, stderr, status = run_cli("scan", "--config", config_path)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "Scan already active for config: #{config_path}"
      assert_equal original_log, File.read(log_path)
    ensure
      if locker
        Process.kill("TERM", locker.pid)
        Process.wait(locker.pid)
      end
    end
  end

  def test_scan_uses_explicit_lock_path_for_active_lock_refusal
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")
      lock_path = File.join(dir, "state", "custom.lock")
      config = scan_config(
        [fake_source("apple", { "state" => "no_match", "message" => "not listed" })]
      ).merge(
        "state" => { "lock_file" => lock_path },
        "run" => { "run_id" => "run-custom-lock" }
      )
      File.write(config_path, YAML.dump(config))
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(
        lock_path,
        JSON.generate(
          "config_path" => config_path,
          "started_at" => Time.now.utc.iso8601,
          "pid" => Process.pid
        )
      )

      _stdout, stderr, status = run_cli("scan", "--config", config_path)

      refute status.success?
      assert_includes stderr, "Lock file: #{lock_path}"
      refute File.exist?(File.join(dir, ".price-sentinel", "scan.lock"))
    end
  end

  def test_scan_recovers_stale_lock_according_to_configured_threshold
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "active.yml")
      log_path = File.join(dir, "price-log.md")
      lock_path = default_lock_path(config_path)
      config = scan_config_with_log(
        [fake_source("apple", { "state" => "no_match", "message" => "not listed" })],
        markdown_log: log_path,
        run_id: "run-recovered"
      )
      config["run"] = config.fetch("run").merge("stale_lock_after_ms" => 1_000)
      File.write(config_path, YAML.dump(config))
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(
        lock_path,
        JSON.generate(
          "config_path" => config_path,
          "started_at" => (Time.now.utc - 3_600).iso8601,
          "pid" => 98_765
        )
      )

      stdout, stderr, status = run_cli("scan", "--config", config_path)

      assert status.success?, stderr
      assert_includes stderr, "Recovered stale scan lock: #{lock_path}"
      assert_includes stdout, "Scan complete: #{config_path}"
      assert_includes File.read(log_path), 'run_id="run-recovered"'
      assert_equal "run-recovered", JSON.parse(File.read(File.join(dir, ".price-sentinel", "last-scan.json"))).fetch("run_id")
      refute File.exist?(lock_path)
    end
  end

  def test_default_lock_for_one_config_does_not_refuse_a_different_config_in_same_directory
    Dir.mktmpdir do |dir|
      first_config_path = File.join(dir, "first.yml")
      second_config_path = File.join(dir, "second.yml")
      first_lock_path = default_lock_path(first_config_path)
      File.write(
        first_config_path,
        YAML.dump(scan_config([fake_source("apple", { "state" => "no_match", "message" => "not listed" })]))
      )
      File.write(
        second_config_path,
        YAML.dump(scan_config([fake_source("apple", { "state" => "no_match", "message" => "not listed" })]))
      )
      FileUtils.mkdir_p(File.dirname(first_lock_path))
      File.write(
        first_lock_path,
        JSON.generate(
          "config_path" => first_config_path,
          "started_at" => Time.now.utc.iso8601,
          "pid" => Process.pid
        )
      )

      stdout, stderr, status = run_cli("scan", "--config", second_config_path)

      assert status.success?, stderr
      assert_includes stdout, "Scan complete: #{second_config_path}"
      assert File.exist?(first_lock_path)
      refute File.exist?(default_lock_path(second_config_path))
    end
  end

  def test_default_lock_for_shared_state_dir_is_scoped_by_full_config_path
    Dir.mktmpdir do |dir|
      first_config_path = File.join(dir, "one", "active.yml")
      second_config_path = File.join(dir, "two", "active.yml")
      shared_state_dir = File.join(dir, "shared-state")
      first_lock_path = default_lock_path(first_config_path, state_dir: shared_state_dir)
      [first_config_path, second_config_path].each do |config_path|
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(
          config_path,
          YAML.dump(
            scan_config([fake_source("apple", { "state" => "no_match", "message" => "not listed" })]).merge(
              "state" => { "dir" => shared_state_dir }
            )
          )
        )
      end
      FileUtils.mkdir_p(shared_state_dir)
      File.write(
        first_lock_path,
        JSON.generate(
          "config_path" => first_config_path,
          "started_at" => Time.now.utc.iso8601,
          "pid" => Process.pid
        )
      )

      stdout, stderr, status = run_cli("scan", "--config", second_config_path)

      assert status.success?, stderr
      assert_includes stdout, "Scan complete: #{second_config_path}"
      assert File.exist?(first_lock_path)
      refute File.exist?(default_lock_path(second_config_path, state_dir: shared_state_dir))
    end
  end
end
