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
      when "apple_ca_product_page"
        AppleCanadaProductPageExtractor
      when "generic_product_page"
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
      when /Refurbished/i
        "refurbished"
      when /UsedCondition/i
        "used"
      else
        named_value(value)
      end
    end

    def normalize_availability(value)
      case value.to_s
      when /(?:Not\s+In\s*Stock|Out\s*Of\s*Stock|OutOfStock|Unavailable)/i
        "out_of_stock"
      when /In\s*Stock/i
        "in_stock"
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

  module AppleCanadaProductPageExtractor
    module_function

    def extract(source)
      response = ProductPageExtractor.fetch_page(source.fetch("url"))
      status = response.code.to_i

      if ProductPageExtractor::BLOCKED_HTTP_STATUSES.include?(status)
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

      body = ProductPageExtractor.normalize_body(response.body)
      if blocked_body?(body)
        return {
          "state" => "blocked",
          "message" => "source returned an access-denied or challenge page"
        }
      end

      product, observed_body = product_for_source(body, source)
      return { "state" => "uncertain", "message" => "product data could not be extracted" } unless product

      price = ProductPageExtractor.extract_price(product)
      currency = ProductPageExtractor.extract_currency(product)
      unless price && currency
        return { "state" => "uncertain", "message" => "price data could not be extracted" }
      end

      {
        "state" => "found",
        "price" => {
          "amount" => price,
          "currency" => currency
        },
        "observed" => ProductPageExtractor.extract_observed(product, source, observed_body)
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

    def apple_product_candidates(body)
      json_candidates = json_script_values(body).flat_map { |value| product_hashes(value) }.map do |hash|
        candidate_from_hash(hash)
      end.compact
      json_candidates + html_product_candidates(body)
    end

    def blocked_body?(body)
      text = ProductPageExtractor.visible_text(body)
      text.match?(/access denied|verify you are human|captcha|temporarily blocked|unusual traffic/i) ||
        body.match?(/akamai[-_ ]?(?:bot|challenge|error)|bot[-_ ]?detect|challenge-platform/i)
    end

    def product_for_source(body, source)
      candidates = apple_product_candidates(body).map { |candidate| [candidate, ""] }
      generic_product = generic_product(body)
      candidates << [generic_product, body] if generic_product

      select_candidate(candidates, source["expected_attributes"]) || [nil, ""]
    end

    def select_candidate(candidates, expected_attributes)
      return candidates.first unless expected_attributes.is_a?(Hash)

      candidates.find do |(candidate, _observed_body)|
        observed = ProductPageExtractor.extract_attributes(candidate, "", { "extractor" => "apple_ca_product_page" })
        expected_attributes.all? do |name, expected_value|
          expected_value.nil? || observed[name] == expected_value
        end
      end || candidates.first
    end

    def generic_product(body)
      ProductPageExtractor.extract_product(body)
    rescue JSON::ParserError
      nil
    end

    def json_script_values(body)
      body.scan(%r{<script[^>]+type=["']application/json["'][^>]*>(.*?)</script>}im).map do |(raw_json)|
        begin
          JSON.parse(CGI.unescapeHTML(raw_json.strip))
        rescue JSON::ParserError
          nil
        end
      end.compact
    end

    def product_hashes(value)
      case value
      when Array
        value.flat_map { |entry| product_hashes(entry) }
      when Hash
        [value] + value.values.flat_map { |entry| product_hashes(entry) }
      else
        []
      end
    end

    def candidate_from_hash(hash)
      name = first_present(hash["title"], hash["name"], hash["productName"], hash["family"])
      amount, currency = price_candidate(hash)
      return nil unless name && amount && currency

      description = first_present(hash["description"], hash["specs"], hash["summary"])
      candidate_text = [name, description].compact.join(" ")
      {
        "@type" => "Product",
        "name" => name,
        "description" => description,
        "brand" => first_present(hash["brand"], "Apple"),
        "sku" => first_present(hash["partNumber"], hash["sku"]),
        "offers" => {
          "@type" => "Offer",
          "price" => amount,
          "priceCurrency" => currency,
          "availability" => hash["availability"] || visible_availability(candidate_text),
          "itemCondition" => hash["condition"] || visible_condition(candidate_text),
          "seller" => { "name" => "Apple Canada" }
        }
      }
    end

    def html_product_candidates(body)
      product_tile_fragments(body).map do |html|
        candidate_from_html(html)
      end.compact
    end

    def product_tile_fragments(body)
      fragments = []
      position = 0
      opening_tag = /<(article|li|div)\b([^>]*)>/im

      while (match = body.match(opening_tag, position))
        tag_name = match[1]
        attrs = match[2]
        position = match.end(0)
        next unless product_tile_attributes?(attrs)

        closing = matching_closing_tag(body, tag_name, position)
        next unless closing

        close_start, close_end = closing
        fragments << body[position...close_start]
        position = close_end
      end

      fragments
    end

    def product_tile_attributes?(attrs)
      attrs.match?(/(?:class|data-testid|data-autom)=["'][^"']*(?:rfb-producttile|producttile|product-tile)[^"']*["']/i)
    end

    def matching_closing_tag(body, tag_name, position)
      depth = 1
      tag_pattern = %r{</?#{Regexp.escape(tag_name)}\b[^>]*>}im

      while (match = body.match(tag_pattern, position))
        token = match[0]
        if token.start_with?("</")
          depth -= 1
          return [match.begin(0), match.end(0)] if depth.zero?
        else
          depth += 1
        end
        position = match.end(0)
      end

      nil
    end

    def candidate_from_html(html)
      text = ProductPageExtractor.visible_text(html).gsub(/\s+/, " ").strip
      name = first_present(heading_text(html), text.split(/(?:Condition:|Availability:|From\s+\$)/i).first&.strip)
      price = visible_price(text)
      return nil unless name && price

      {
        "@type" => "Product",
        "name" => name,
        "description" => text,
        "brand" => "Apple",
        "offers" => {
          "@type" => "Offer",
          "price" => price.fetch("amount"),
          "priceCurrency" => price.fetch("currency"),
          "availability" => visible_availability(text),
          "itemCondition" => visible_condition(text),
          "seller" => { "name" => "Apple Canada" }
        }
      }
    end

    def heading_text(html)
      match = html.match(%r{<h[1-6][^>]*>(.*?)</h[1-6]>}im)
      ProductPageExtractor.visible_text(match[1]) if match
    end

    def visible_price(text)
      match = text.match(/\bFrom\s+(?:CAD\s*)?\$([0-9][0-9,]*(?:\.[0-9]{2})?)/i) || first_non_savings_price(text)
      return nil unless match

      {
        "amount" => match[1].delete(","),
        "currency" => "CAD"
      }
    end

    def first_non_savings_price(text)
      text.to_enum(:scan, /(?:CAD\s*)?\$([0-9][0-9,]*(?:\.[0-9]{2})?)/i).each do
        match = Regexp.last_match
        prefix = text[[match.begin(0) - 12, 0].max...match.begin(0)]
        return match unless prefix.match?(/(?:save|savings|was)\s*$/i)
      end

      nil
    end

    def visible_condition(text)
      return "refurbished" if text.match?(/refurbished/i)
      return "new" if text.match?(/\bnew\b/i)

      nil
    end

    def visible_availability(text)
      return "OutOfStock" if text.match?(/\b(?:not\s+in\s*stock|out\s*of\s*stock|unavailable)\b/i)
      return "In Stock" if text.match?(/\bin\s*stock\b/i)

      nil
    end

    def price_candidate(hash)
      price_data = first_hash(hash["priceData"], hash["price"])
      current_price = first_hash(price_data && price_data["currentPrice"], price_data)
      amount = first_present(
        current_price && current_price["amount"],
        current_price && current_price["value"],
        hash["price"],
        hash["currentPrice"],
        hash["fullPrice"]
      )
      currency = first_present(
        current_price && current_price["currency"],
        current_price && current_price["currencyCode"],
        hash["currency"],
        hash["currencyCode"]
      )

      [amount, currency]
    end

    def first_hash(*values)
      values.find { |value| value.is_a?(Hash) }
    end

    def first_present(*values)
      values.find { |value| !value.nil? && value != "" }
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
