# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"

module PriceSentinel
  module SourceExtractors
    SUPPORTED_NAMES = %w[
      apple_ca_product_page
      fake_source
      generic_product_page
    ].freeze

    module_function

    def fetch(name)
      case name
      when "fake_source"
        FakeSourceExtractor
      when "apple_ca_product_page", "generic_product_page"
        ProductPageExtractor
      else
        UnsupportedExtractor
      end
    end
  end

  module FakeSourceExtractor
    VALID_STATES = %w[found no_match uncertain blocked error].freeze

    module_function

    def extract(source)
      result = source.fetch("fake_result", {})
      state = result["state"].to_s
      raise ArgumentError, "fake_result.state is unsupported: #{state}" unless VALID_STATES.include?(state)

      {
        "state" => state,
        "price" => result["price"],
        "observed" => result.fetch("observed", {}),
        "message" => result["message"]
      }
    end
  end

  module ProductPageExtractor
    BLOCKED_HTTP_STATUSES = [401, 403, 407, 429].freeze

    module_function

    def extract(source)
      response = fetch_page(source.fetch("url"))
      status = response.code.to_i

      if BLOCKED_HTTP_STATUSES.include?(status)
        return {
          "state" => "blocked",
          "message" => "source returned HTTP #{status}"
        }
      end

      unless status.between?(200, 299)
        return {
          "state" => "error",
          "message" => "source returned HTTP #{status}"
        }
      end

      body = normalize_body(response.body)
      product = extract_product(body)
      return { "state" => "uncertain", "message" => "product data could not be extracted" } unless product

      price = extract_price(product)
      currency = extract_currency(product)
      unless price && currency
        return { "state" => "uncertain", "message" => "price data could not be extracted" }
      end

      {
        "state" => "found",
        "price" => {
          "amount" => price,
          "currency" => currency
        },
        "observed" => extract_observed(product, source, body)
      }
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      {
        "state" => "error",
        "message" => "product page request failed: #{e.class}: #{e.message}"
      }
    rescue JSON::ParserError => e
      {
        "state" => "uncertain",
        "message" => "product data could not be parsed: #{e.message}"
      }
    end

    def fetch_page(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "PriceSentinel/1.0"

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 10,
        read_timeout: 10
      ) do |http|
        http.request(request)
      end
    end

    def normalize_body(body)
      body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def extract_product(body)
      json_ld_products(body).find { |node| type_includes?(node, "Product") } || meta_product(body)
    end

    def json_ld_products(body)
      body.scan(%r{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}im).flat_map do |(raw_json)|
        flatten_json_ld(JSON.parse(CGI.unescapeHTML(raw_json.strip)))
      end
    end

    def flatten_json_ld(value)
      case value
      when Array
        value.flat_map { |entry| flatten_json_ld(entry) }
      when Hash
        nested = Array(value["@graph"]).flat_map { |entry| flatten_json_ld(entry) }
        [value] + nested
      else
        []
      end
    end

    def meta_product(body)
      amount = meta_content(body, "product:price:amount")
      currency = meta_content(body, "product:price:currency")
      return nil unless amount && currency

      {
        "offers" => {
          "price" => amount,
          "priceCurrency" => currency,
          "availability" => meta_content(body, "product:availability"),
          "itemCondition" => meta_content(body, "product:condition")
        },
        "brand" => meta_content(body, "product:brand")
      }
    end

    def meta_content(body, property)
      match = body.match(%r{<meta[^>]+(?:property|name)=["']#{Regexp.escape(property)}["'][^>]+content=["']([^"']+)["'][^>]*>}i) ||
              body.match(%r{<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']#{Regexp.escape(property)}["'][^>]*>}i)
      CGI.unescapeHTML(match[1]) if match
    end

    def extract_price(product)
      value = offer_value(product, "price") || offer_value(product, "lowPrice")
      Float(value) if value
    rescue ArgumentError, TypeError
      nil
    end

    def extract_currency(product)
      offer_value(product, "priceCurrency")
    end

    def extract_observed(product, source, body)
      {
        "condition" => normalize_condition(offer_value(product, "itemCondition")) || default_condition(source),
        "seller" => named_value(offer_value(product, "seller")) || default_seller(source),
        "availability" => normalize_availability(offer_value(product, "availability")),
        "ships_to" => source["expected_country"],
        "attributes" => extract_attributes(product, body, source)
      }.compact
    end

    def offer_value(product, key)
      offers = product["offers"]
      offer = offers.is_a?(Array) ? offers.first : offers
      return nil unless offer.is_a?(Hash)

      offer[key]
    end

    def named_value(value)
      return value["name"] if value.is_a?(Hash)

      value
    end

    def extract_attributes(product, body, source)
      text = product_text(product, body)
      {
        "category" => category(text),
        "brand" => named_value(product["brand"]) || default_brand(source),
        "product_line" => product_line(text),
        "model" => screen_model(text),
        "chip" => chip(text),
        "memory_gb" => memory_gb(text),
        "storage_gb" => storage_gb(text)
      }.compact
    end

    def product_text(product, body)
      [
        product["name"],
        product["description"],
        product["sku"],
        product["mpn"],
        visible_text(body)
      ].compact.join(" ")
    end

    def visible_text(body)
      CGI.unescapeHTML(body.gsub(/<script\b.*?<\/script>/im, " ").gsub(/<[^>]+>/, " "))
    end

    def category(text)
      "laptop" if text.match?(/MacBook/i)
    end

    def product_line(text)
      return "MacBook Air" if text.match?(/MacBook\s+Air/i)
      return "MacBook Pro" if text.match?(/MacBook\s+Pro/i)

      nil
    end

    def screen_model(text)
      match = text.match(/(\d+(?:\.\d+)?)\s*(?:-| )?inch/i)
      "#{match[1]}-inch" if match
    end

    def chip(text)
      match = text.match(/\b(M\d(?:\s+(?:Pro|Max|Ultra))?)\b/i)
      match[1].split.map(&:capitalize).join(" ") if match
    end

    def memory_gb(text)
      match = text.match(/(\d+)\s*GB\s+(?:unified\s+)?memory/i)
      return match[1].to_i if match

      capacities = gb_capacities(text)
      capacities.find { |capacity| capacity < 128 }
    end

    def storage_gb(text)
      match = text.match(/(\d+)\s*(GB|TB)\s+(?:SSD\s+)?storage/i)
      return capacity_to_gb(match[1], match[2]) if match

      ssd_match = text.match(/(\d+)\s*(GB|TB)\s+SSD/i)
      return capacity_to_gb(ssd_match[1], ssd_match[2]) if ssd_match

      capacities = gb_capacities(text)
      capacities.reverse.find { |capacity| capacity >= 128 }
    end

    def gb_capacities(text)
      text.scan(/(\d+)\s*(GB|TB)\b/i).map { |amount, unit| capacity_to_gb(amount, unit) }
    end

    def capacity_to_gb(amount, unit)
      value = amount.to_i
      unit.casecmp("TB").zero? ? value * 1024 : value
    end

    def type_includes?(node, type)
      Array(node["@type"]).include?(type)
    end

    def normalize_condition(value)
      case value.to_s
      when /NewCondition/i
        "new"
      when /UsedCondition/i
        "used"
      else
        named_value(value)
      end
    end

    def normalize_availability(value)
      case value.to_s
      when /InStock/i
        "in_stock"
      when /OutOfStock/i
        "out_of_stock"
      when /PreOrder/i
        "preorder"
      else
        named_value(value)
      end
    end

    def default_condition(source)
      "new" if source["extractor"] == "apple_ca_product_page"
    end

    def default_seller(source)
      "Apple Canada" if source["extractor"] == "apple_ca_product_page"
    end

    def default_brand(source)
      "Apple" if source["extractor"] == "apple_ca_product_page"
    end
  end

  module UnsupportedExtractor
    module_function

    def extract(source)
      {
        "state" => "error",
        "message" => "extractor is not implemented for scan: #{source["extractor"]}"
      }
    end
  end
end
