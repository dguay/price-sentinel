# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "openssl"
require "pathname"
require "timeout"
require "uri"
require "yaml"
require_relative "config_validator"

module PriceSentinel
  module SourceDiagnosis
    DEFAULT_MAX_REDIRECTS = 5

    module_function

    def diagnose_file(path, check_id:, source_id:)
      validation = ConfigValidator.validate_file(path)
      raise InvalidConfigError, validation.errors unless validation.valid?

      config = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      check, source = find_enabled_source(config, check_id, source_id)
      response = fetch(source.fetch("url"))
      body = response.fetch("body")

      diagnosis = {
        "config_path" => path,
        "source_identity" => {
          "check_id" => check.fetch("id"),
          "source_id" => source.fetch("id"),
          "retailer" => source["retailer"],
          "extractor" => source["extractor"]
        },
        "requested_url" => source.fetch("url"),
        "final_url" => response.fetch("final_url"),
        "http_status" => response.fetch("status"),
        "page_title" => page_title(body),
        "structured_offer_candidates" => structured_offer_candidates(body),
        "visible_candidates" => visible_candidates(body),
        "suggested_extractor_changes" => [
          "Review this evidence and update extractor code manually if needed."
        ]
      }

      diagnosis.merge!(saved_artifacts(config, path, check, source, body))
      diagnosis
    end

    def find_enabled_source(config, check_id, source_id)
      check = Array(config["checks"]).find do |candidate|
        ConfigValidator.enabled?(candidate) && candidate["id"] == check_id
      end
      raise SourceDiagnosisError, "Enabled check not found: #{check_id}" unless check

      source = Array(check["sources"]).find do |candidate|
        ConfigValidator.enabled?(candidate) && candidate["id"] == source_id
      end
      raise SourceDiagnosisError, "Enabled source not found for #{check_id}: #{source_id}" unless source

      [check, source]
    end

    def fetch(url, redirects_remaining: DEFAULT_MAX_REDIRECTS)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri))
      end

      if response.is_a?(Net::HTTPRedirection) && redirects_remaining.positive?
        location = URI.join(url, response.fetch("location")).to_s
        return fetch(location, redirects_remaining: redirects_remaining - 1)
      end

      {
        "final_url" => url,
        "status" => response.code.to_i,
        "body" => response.body.to_s
      }
    rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise SourceDiagnosisError, "Source diagnosis failed: #{e.message}"
    end

    def page_title(html)
      match = html.match(%r{<title[^>]*>(.*?)</title>}im)
      normalize_text(match && match[1])
    end

    def structured_offer_candidates(html)
      html.scan(%r{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}im).flat_map do |match|
        json_ld_products(JSON.parse(match.first))
      rescue JSON::ParserError
        []
      end
    end

    def json_ld_products(value)
      case value
      when Array
        value.flat_map { |entry| json_ld_products(entry) }
      when Hash
        graph = value["@graph"]
        return json_ld_products(graph) if graph

        type = Array(value["@type"]).map(&:to_s)
        return [structured_offer_candidate(value)].compact if type.include?("Product")

        []
      else
        []
      end
    end

    def structured_offer_candidate(product)
      offer = first_mapping(product["offers"])
      return nil unless offer.is_a?(Hash)

      {
        "name" => product["name"],
        "price" => price_candidate(offer["price"], offer["priceCurrency"]),
        "seller" => nested_name(offer["seller"]),
        "condition" => normalized_condition(offer["itemCondition"]),
        "availability" => normalized_availability(offer["availability"])
      }.compact
    end

    def first_mapping(value)
      return value if value.is_a?(Hash)
      return value.find { |entry| entry.is_a?(Hash) } if value.is_a?(Array)

      nil
    end

    def visible_candidates(html)
      text = normalize_text(html.gsub(/<script.*?<\/script>/im, " ").gsub(/<[^>]+>/, " "))
      {
        "product_title" => visible_titles(html),
        "prices" => visible_prices(text),
        "sellers" => visible_sellers(text),
        "conditions" => visible_conditions(text),
        "availability" => visible_availability(text)
      }
    end

    def visible_titles(html)
      html.scan(%r{<h1[^>]*>(.*?)</h1>}im).map { |match| normalize_text(strip_tags(match.first)) }.compact.uniq
    end

    def visible_prices(text)
      text.scan(/(?:\$|CAD\s*)\s*([0-9][0-9,]*(?:\.[0-9]{2})?)\s*(CAD)?/i).map do |amount, trailing_currency|
        currency = trailing_currency || (text.match?(/CAD/i) ? "CAD" : nil)
        price_candidate(amount, currency)
      end.compact.uniq
    end

    def visible_sellers(text)
      text.scan(/Sold by\s+([^:]+?)(?:\s+Condition:|\s+Availability:|$)/i).map do |match|
        normalize_text(match.first)
      end.compact.uniq
    end

    def visible_conditions(text)
      values = []
      values << "new" if text.match?(/\bCondition:\s*New\b/i)
      values.uniq
    end

    def visible_availability(text)
      values = []
      values << "in_stock" if text.match?(/\bAvailability:\s*In stock\b/i)
      values.uniq
    end

    def saved_artifacts(config, config_path, check, source, body)
      diagnosis_config = diagnosis_config(config, source)
      return {} unless diagnosis_config["save_html"] == true

      dir = diagnosis_config["artifact_dir"] || File.join(".price-sentinel", "diagnostics")
      path = resolve_path(dir, File.dirname(config_path))
      FileUtils.mkdir_p(path)
      html_path = File.join(path, "#{check.fetch("id")}-#{source.fetch("id")}.html")
      File.write(html_path, body)
      { "saved_html_path" => html_path }
    end

    def diagnosis_config(config, source)
      top_level = config["diagnostics"].is_a?(Hash) ? config["diagnostics"] : {}
      source_level = source["diagnostics"].is_a?(Hash) ? source["diagnostics"] : {}
      top_level.merge(source_level)
    end

    def nested_name(value)
      value.is_a?(Hash) ? value["name"] : value
    end

    def price_candidate(amount, currency)
      return nil if amount.nil? || currency.nil?

      {
        "amount" => Float(amount.to_s.delete(",")),
        "currency" => currency.to_s.upcase
      }
    rescue ArgumentError
      nil
    end

    def normalized_condition(value)
      case value.to_s
      when /NewCondition/i
        "new"
      else
        normalize_text(value)
      end
    end

    def normalized_availability(value)
      case value.to_s
      when /InStock/i
        "in_stock"
      else
        normalize_text(value)
      end
    end

    def strip_tags(value)
      value.to_s.gsub(/<[^>]+>/, " ")
    end

    def normalize_text(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      text.empty? ? nil : text
    end

    def resolve_path(path, base_dir)
      return path if Pathname.new(path).absolute?

      File.expand_path(path, base_dir)
    end
  end

  class SourceDiagnosisError < StandardError; end
end
