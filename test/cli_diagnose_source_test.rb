# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

class CliDiagnoseSourceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "price-sentinel")

  def run_cli(*args)
    Open3.capture3(CLI, *args)
  end

  def with_config(config)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "active.yml")
      File.write(path, YAML.dump(config))
      yield path, dir
    end
  end

  def with_http_server(response_body, status: "200 OK", headers: {})
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        while (line = client.gets)
          break if line == "\r\n"
        end
        client.write "HTTP/1.1 #{status}\r\n"
        headers.merge("Content-Type" => "text/html; charset=utf-8").each do |key, value|
          client.write "#{key}: #{value}\r\n"
        end
        client.write "Content-Length: #{response_body.bytesize}\r\n"
        client.write "Connection: close\r\n\r\n"
        client.write response_body
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

  def with_redirect_server(final_body)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        while (line = client.gets)
          break if line == "\r\n"
        end

        if request_line.include?(" /redirect ")
          location = "http://127.0.0.1:#{port}/final-product"
          client.write "HTTP/1.1 302 Found\r\n"
          client.write "Location: #{location}\r\n"
          client.write "Content-Length: 0\r\n"
          client.write "Connection: close\r\n\r\n"
        else
          client.write "HTTP/1.1 200 OK\r\n"
          client.write "Content-Type: text/html; charset=utf-8\r\n"
          client.write "Content-Length: #{final_body.bytesize}\r\n"
          client.write "Connection: close\r\n\r\n"
          client.write final_body
        end
        client.close
      end
    rescue IOError, Errno::EBADF
      # Server closed by the test.
    end

    yield "http://127.0.0.1:#{port}/redirect", "http://127.0.0.1:#{port}/final-product"
  ensure
    server&.close
    thread&.join(2)
  end

  def unused_local_url
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    "http://127.0.0.1:#{port}/unreachable"
  end

  def config_for(source_url, output: nil)
    config = {
      "version" => 1,
      "alerts" => { "enabled" => false },
      "checks" => [
        {
          "id" => "macbook-air",
          "enabled" => true,
          "product_name" => "MacBook Air",
          "target" => { "amount" => 1799, "currency" => "CAD" },
          "sources" => [
            {
              "id" => "retailer",
              "enabled" => true,
              "retailer" => "Example Retailer",
              "extractor" => "generic_product_page",
              "url" => source_url
            }
          ]
        }
      ]
    }
    config["output"] = output if output
    config
  end

  def test_diagnose_source_reports_http_and_candidate_evidence_for_configured_source
    body = <<~HTML
      <!doctype html>
      <html>
        <head>
          <title>MacBook Air Deal</title>
          <script type="application/ld+json">
            {"@type":"Product","name":"MacBook Air 15-inch","offers":{"@type":"Offer","price":"1699.00","priceCurrency":"CAD","availability":"https://schema.org/InStock","seller":{"name":"Example Retailer"},"itemCondition":"https://schema.org/NewCondition"}}
          </script>
        </head>
        <body>
          <h1>MacBook Air 15-inch</h1>
          <p>Sold by Example Retailer</p>
          <p>Condition: New</p>
          <p>Availability: In stock</p>
          <span>$1,699.00 CAD</span>
        </body>
      </html>
    HTML

    with_http_server(body) do |url|
      with_config(config_for(url)) do |path, dir|
        stdout, stderr, status = run_cli(
          "diagnose-source",
          "--config", path,
          "--check", "macbook-air",
          "--source", "retailer"
        )

        assert status.success?, stderr
        diagnosis = JSON.parse(stdout)
        assert_equal path, diagnosis.fetch("config_path")
        assert_equal "macbook-air", diagnosis.dig("source_identity", "check_id")
        assert_equal "retailer", diagnosis.dig("source_identity", "source_id")
        assert_equal "Example Retailer", diagnosis.dig("source_identity", "retailer")
        assert_equal url, diagnosis.fetch("requested_url")
        assert_equal url, diagnosis.fetch("final_url")
        assert_equal 200, diagnosis.fetch("http_status")
        assert_equal "MacBook Air Deal", diagnosis.fetch("page_title")
        assert_equal(
          {
            "name" => "MacBook Air 15-inch",
            "price" => { "amount" => 1699.0, "currency" => "CAD" },
            "seller" => "Example Retailer",
            "condition" => "new",
            "availability" => "in_stock"
          },
          diagnosis.fetch("structured_offer_candidates").first
        )
        assert_equal "MacBook Air 15-inch", diagnosis.dig("visible_candidates", "product_title").first
        assert_equal({ "amount" => 1699.0, "currency" => "CAD" }, diagnosis.dig("visible_candidates", "prices").first)
        assert_includes diagnosis.dig("visible_candidates", "sellers"), "Example Retailer"
        assert_includes diagnosis.dig("visible_candidates", "conditions"), "new"
        assert_includes diagnosis.dig("visible_candidates", "availability"), "in_stock"
        assert_equal(
          ["Review this evidence and update extractor code manually if needed."],
          diagnosis.fetch("suggested_extractor_changes")
        )
        refute diagnosis.key?("saved_html_path")
        refute diagnosis.key?("screenshot_path")
        refute File.exist?(File.join(dir, ".price-sentinel", "last-scan.json"))
      end
    end
  end

  def test_diagnose_source_saves_html_only_when_configured
    body = <<~HTML
      <html>
        <head><title>Saved Artifact</title></head>
        <body><h1>MacBook Air</h1></body>
      </html>
    HTML

    with_http_server(body) do |url|
      with_config(
        config_for(
          url,
          output: nil
        ).merge("diagnostics" => { "save_html" => true, "artifact_dir" => "diagnosis-artifacts" })
      ) do |path, dir|
        stdout, stderr, status = run_cli(
          "diagnose-source",
          "--config", path,
          "--check", "macbook-air",
          "--source", "retailer"
        )

        assert status.success?, stderr
        diagnosis = JSON.parse(stdout)
        html_path = diagnosis.fetch("saved_html_path")
        assert_equal File.join(dir, "diagnosis-artifacts", "macbook-air-retailer.html"), html_path
        assert_equal body, File.read(html_path)
        refute diagnosis.key?("screenshot_path")
      end
    end
  end

  def test_diagnose_source_uses_source_level_diagnostics_config_for_saved_html
    body = "<html><head><title>Source Artifact</title></head><body></body></html>"

    with_http_server(body) do |url|
      config = config_for(url)
      config.fetch("checks").first.fetch("sources").first["diagnostics"] = {
        "save_html" => true,
        "artifact_dir" => "source-diagnosis-artifacts"
      }

      with_config(config) do |path, dir|
        stdout, stderr, status = run_cli(
          "diagnose-source",
          "--config", path,
          "--check", "macbook-air",
          "--source", "retailer"
        )

        assert status.success?, stderr
        diagnosis = JSON.parse(stdout)
        html_path = diagnosis.fetch("saved_html_path")
        assert_equal File.join(dir, "source-diagnosis-artifacts", "macbook-air-retailer.html"), html_path
        assert_equal body, File.read(html_path)
      end
    end
  end

  def test_diagnose_source_reports_final_url_after_redirects
    body = "<html><head><title>Final Product</title></head><body></body></html>"

    with_redirect_server(body) do |start_url, final_url|
      with_config(config_for(start_url)) do |path, _dir|
        stdout, stderr, status = run_cli(
          "diagnose-source",
          "--config", path,
          "--check", "macbook-air",
          "--source", "retailer"
        )

        assert status.success?, stderr
        diagnosis = JSON.parse(stdout)
        assert_equal start_url, diagnosis.fetch("requested_url")
        assert_equal final_url, diagnosis.fetch("final_url")
        assert_equal 200, diagnosis.fetch("http_status")
        assert_equal "Final Product", diagnosis.fetch("page_title")
      end
    end
  end

  def test_diagnose_source_reports_clean_error_when_source_cannot_be_fetched
    with_config(config_for(unused_local_url)) do |path, _dir|
      stdout, stderr, status = run_cli(
        "diagnose-source",
        "--config", path,
        "--check", "macbook-air",
        "--source", "retailer"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "Source diagnosis failed:"
      refute_includes stderr, "source_diagnosis.rb"
    end
  end

  def test_scan_does_not_run_source_diagnosis_when_diagnostics_are_configured
    with_http_server("<html><head><title>Product</title></head><body>No structured product data</body></html>") do |url|
      with_config(
        config_for(
          url,
          output: nil
        ).merge("diagnostics" => { "save_html" => true, "artifact_dir" => "diagnosis-artifacts" })
      ) do |path, dir|
        stdout, stderr, status = run_cli("scan", "--config", path)

        assert status.success?, stderr
        assert_includes stdout, "[uncertain] macbook-air/retailer no price - product data could not be extracted"
        refute File.exist?(File.join(dir, "diagnosis-artifacts"))
      end
    end
  end
end
