# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"
require_relative "encoding"

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
        "product_url" => result["product_url"],
        "observed" => result.fetch("observed", {}),
        "message" => result["message"]
      }
    end
  end

  module ProductPageExtractor
    BLOCKED_HTTP_STATUSES = [401, 403, 407, 429].freeze
    SEARCH_TILE_CLASS_PATTERN = /(?:product-item|search-result|product-card|card-wrapper|grid__item)/i

    module_function

    def extract(source)
      response = fetch_page(source.fetch("url"))
      status = response.code.to_i
      body = normalize_body(response.body)

      if BLOCKED_HTTP_STATUSES.include?(status)
        return {
          "state" => "blocked",
          "message" => "source returned HTTP #{status}"
        }
      end

      if blocked_body?(body) || amazon_ca_blocked_503?(status, body, source)
        return {
          "state" => "blocked",
          "message" => "source returned HTTP #{status} access barrier"
        }
      end

      unless status.between?(200, 299)
        return {
          "state" => "error",
          "message" => "source returned HTTP #{status}"
        }
      end

      product, observed_body, candidate_count = select_product(body, source)
      unless product
        if candidate_count.positive? || no_results_body?(body)
          return { "state" => "no_match", "message" => "matching product was not found" }
        end

        return { "state" => "uncertain", "message" => "product data could not be extracted" }
      end

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
        "product_url" => product_url(product, source),
        "observed" => extract_observed(product, source, observed_body)
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
      PriceSentinel::Encoding.normalize_body(body)
    end

    def blocked_body?(body)
      text = visible_text(body)
      text.match?(/access denied|verify you are human|captcha|temporarily blocked|unusual traffic/i) ||
        body.match?(/akamai[-_ ]?(?:bot|challenge|error)|bot[-_ ]?detect|challenge-platform/i)
    end

    def amazon_ca_blocked_503?(status, body, source)
      status == 503 && source["retailer"].to_s == "amazon_ca" &&
        body.match?(/Amazon\.ca Something Went Wrong|Sorry!\s*Something went wrong/i)
    end

    def no_results_body?(body)
      text = visible_text(body)
      body.match?(/"TotalItemCount"\s*:\s*0\b|["']search_results_count["']\s*:\s*["']0["']/i) ||
        text.match?(/\b(?:0|zero)\s+(?:results|items|products)\b|no\s+(?:results|items|products)\s+(?:found|match)/i)
    end

    def extract_product(body, source = {})
      product_candidates(body, source).first&.first
    end

    def select_product(body, source)
      candidates = product_candidates(body, source)
      return [nil, "", 0] if candidates.empty?

      expected_attributes = source["expected_attributes"]
      if expected_attributes.is_a?(Hash) && expected_attributes.values.any?
        match = candidates.find do |candidate, candidate_body|
          observed = extract_attributes(candidate, candidate_body, source)
          expected_attributes.all? do |name, expected_value|
            expected_value.nil? || observed[name] == expected_value
          end
        end
        return [match[0], match[1], candidates.length] if match

        return [nil, "", candidates.length]
      end

      [candidates.first[0], candidates.first[1], candidates.length]
    end

    def product_candidates(body, source)
      candidates = json_ld_products(body)
                   .select { |node| type_includes?(node, "Product") }
                   .map { |node| [node, body] }
      meta = meta_product(body)
      candidates << [meta, body] if meta
      candidates.concat(application_json_product_candidates(body, source).map { |candidate| [candidate, body] })
      candidates.concat(javascript_product_candidates(body, source).map { |candidate| [candidate, body] })
      candidates.concat(html_product_candidates(body, source).map { |candidate| [candidate, candidate["description"].to_s] })
      unique_candidates(candidates)
    end

    def unique_candidates(candidates)
      seen = {}
      candidates.select do |candidate, _candidate_body|
        key = [
          candidate["name"].to_s.downcase.gsub(/\s+/, " ").strip,
          offer_value(candidate, "price").to_s,
          offer_value(candidate, "priceCurrency").to_s
        ]
        next false if key.first.empty? || seen[key]

        seen[key] = true
      end
    end

    def json_ld_products(body)
      body.scan(%r{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}im).flat_map do |(raw_json)|
        flatten_json_ld(JSON.parse(CGI.unescapeHTML(raw_json.strip)))
      end
    end

    def application_json_product_candidates(body, source)
      body.scan(%r{<script[^>]+type=["']application/json["'][^>]*>(.*?)</script>}im).flat_map do |(raw_json)|
        value = JSON.parse(CGI.unescapeHTML(raw_json.strip))
        product_hashes(value).map { |hash| candidate_from_mapping(hash, source) }.compact
      rescue JSON::ParserError
        []
      end
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

    def javascript_product_candidates(body, source)
      body.scan(/\{id:\d+,\s*handle:"([^"]*)",\s*title:"((?:\\.|[^"])*)",\s*variants:\[\{(.*?)\}\]\}/m).map do |handle, title, variant|
        price_match = variant.match(/price:(\d+(?:\.\d+)?)/)
        next unless price_match

        inventory_match = variant.match(/inventory_quantity:(-?\d+)/)
        candidate_from_mapping(
          {
            "handle" => unescape_javascript_string(handle),
            "title" => unescape_javascript_string(title),
            "price" => price_match[1],
            "inventory_quantity" => inventory_match && inventory_match[1]
          },
          source,
          price_in_cents: true
        )
      end.compact
    end

    def candidate_from_mapping(hash, source, price_in_cents: cents_price_source?(hash, source))
      name = first_present(
        hash["title"],
        hash["name"],
        hash["productName"],
        hash["untranslatedTitle"],
        hash["handle"]
      )
      amount, currency = price_candidate(hash, source, price_in_cents: price_in_cents)
      return nil unless name && amount && currency

      description = first_present(hash["description"], hash["specs"], hash["summary"], hash["handle"])
      text = [name, description].compact.join(" ")
      {
        "@type" => "Product",
        "name" => normalize_candidate_text(name),
        "description" => normalize_candidate_text(description),
        "brand" => first_present(hash["brand"], default_brand(source), inferred_brand(text)),
        "sku" => first_present(hash["sku"], hash["id"]),
        "offers" => {
          "@type" => "Offer",
          "price" => amount,
          "priceCurrency" => currency,
          "availability" => hash["availability"] || inventory_availability(hash) || visible_availability(text),
          "itemCondition" => hash["condition"] || visible_condition(text),
          "seller" => { "name" => default_seller(source) }
        },
        "url" => first_present(hash["url"], hash["productUrl"], hash["productURL"])
      }
    end

    def price_candidate(hash, source, price_in_cents: false)
      price_data = first_hash(hash["priceData"], hash["price"])
      current_price = first_hash(price_data && price_data["currentPrice"], price_data)
      variant = Array(hash["variants"]).find { |entry| entry.is_a?(Hash) && entry["price"] }
      amount = first_present(
        current_price && current_price["amount"],
        current_price && current_price["value"],
        variant && variant["price"],
        hash["price"],
        hash["currentPrice"],
        hash["fullPrice"]
      )
      currency = first_present(
        current_price && current_price["currency"],
        current_price && current_price["currencyCode"],
        hash["currency"],
        hash["currencyCode"],
        default_currency(source)
      )

      [normalize_price_amount(amount, cents: price_in_cents), currency]
    end

    def first_hash(*values)
      values.find { |value| value.is_a?(Hash) }
    end

    def first_present(*values)
      values.find { |value| !value.nil? && value != "" }
    end

    def normalize_price_amount(value, cents: false)
      numeric = Float(value.to_s.delete(","))
      cents ? (numeric / 100.0) : numeric
    rescue ArgumentError, TypeError
      nil
    end

    def cents_price_source?(hash, source)
      source["retailer"].to_s == "reebelo_ca" &&
        hash["price"].to_s.match?(/\A\d+\z/) &&
        (hash.key?("compareAtPrice") || hash.key?("productSlug") || hash.key?("productName"))
    end

    def normalize_candidate_text(value)
      return nil if value.nil?

      CGI.unescapeHTML(value.to_s).gsub(/\s+/, " ").strip
    end

    def unescape_javascript_string(value)
      JSON.parse(%("#{value}"))
    rescue JSON::ParserError
      value.to_s.gsub("\\/", "/").gsub("\\\"", "\"")
    end

    def html_product_candidates(body, source)
      product_tile_fragments(body).map do |html|
        candidate_from_html(html, source)
      end.compact
    end

    def product_tile_fragments(body)
      fragments = []
      position = 0
      opening_tag = /<(article|li|div|a)\b([^>]*)>/im

      while (match = body.match(opening_tag, position))
        tag_name = match[1]
        attrs = match[2]
        position = match.end(0)
        next unless attrs.match?(SEARCH_TILE_CLASS_PATTERN)

        closing = matching_closing_tag(body, tag_name, position)
        next unless closing

        close_start, close_end = closing
        fragments << body[position...close_start]
        position = close_end
      end

      fragments
    end

    def matching_closing_tag(body, tag_name, position)
      depth = 1
      tag_pattern = %r{</?#{Regexp.escape(tag_name)}\b[^>]*>}im

      while (match = body.match(tag_pattern, position))
        token = match[0]
        if token.start_with?("</")
          depth -= 1
          return [match.begin(0), match.end(0)] if depth.zero?
        elsif !token.end_with?("/>")
          depth += 1
        end
        position = match.end(0)
      end

      nil
    end

    def candidate_from_html(html, source)
      text = visible_text(html).gsub(/\s+/, " ").strip
      name = first_present(heading_text(html), attr_text(html, "aria-label"), attr_text(html, "alt"))
      price = html_price(html, text, source)
      return nil unless name && price

      {
        "@type" => "Product",
        "name" => normalize_candidate_text(name),
        "description" => text,
        "brand" => inferred_brand(text) || default_brand(source),
        "offers" => {
          "@type" => "Offer",
          "price" => price.fetch("amount"),
          "priceCurrency" => price.fetch("currency"),
          "availability" => visible_availability(text),
          "itemCondition" => visible_condition(text),
          "seller" => { "name" => default_seller(source) }
        },
        "url" => product_url_from_html(html, source)
      }
    end

    def heading_text(html)
      match = html.match(%r{<h[1-6][^>]*>\s*<a[^>]*>(.*?)</a>\s*</h[1-6]>}im) ||
              html.match(%r{<h[1-6][^>]*>(.*?)</h[1-6]>}im)
      visible_text(match[1]).gsub(/\s+/, " ").strip if match
    end

    def attr_text(html, name)
      match = html.match(%r{\b#{Regexp.escape(name)}=["']([^"']+)["']}i)
      CGI.unescapeHTML(match[1]).strip if match
    end

    def product_url_from_html(html, source)
      match = html.match(%r{<a\b[^>]*\bhref=["']([^"']+)["']}i)
      return nil unless match

      absolute_url(match[1], source["url"])
    end

    def absolute_url(value, base_url)
      return nil if value.nil? || value.to_s.empty?

      URI.join(base_url, CGI.unescapeHTML(value.to_s)).to_s
    rescue URI::InvalidURIError
      nil
    end

    def html_price(html, text, source)
      preferred = html.match(%r{(?:price-type-price|product-item__pricing_large)[^>]*>\s*(?:Only\s*)?(?:<[^>]+>)*\s*(?:CA\s*)?\$([0-9][0-9,]*(?:\.[0-9]{2})?)}im)
      amount = preferred && preferred[1]
      amount ||= visible_price_amount(text)
      return nil unless amount

      {
        "amount" => amount.delete(","),
        "currency" => default_currency(source) || "CAD"
      }
    end

    def visible_price_amount(text)
      text.to_enum(:scan, /(?:CA\s*)?\$([0-9][0-9,]*(?:\.[0-9]{2})?)/i).each do
        match = Regexp.last_match
        # 20 chars covers common prefix labels like save, was, and original price.
        prefix = text[[match.begin(0) - 20, 0].max...match.begin(0)]
        return match[1] unless prefix.match?(/(?:save|savings|was|original)\s*$/i)
      end

      nil
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

    def product_url(product, source)
      absolute_url(
        first_present(product["url"], offer_value(product, "url")),
        source["url"]
      )
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
      CGI.unescapeHTML(body.to_s.gsub(/<script\b.*?<\/script>/im, " ").gsub(/<[^>]+>/, " "))
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
      match = text.match(/(\d+(?:\.\d+)?)\s*(?:-| )?inch/i) ||
              text.match(/(\d+(?:\.\d+)?)\s*(?:"|in\b)/i)
      return nil unless match

      size = match[1].to_f
      return "13-inch" if size.between?(13.0, 13.9)
      return "15-inch" if size.between?(15.0, 15.9)

      "#{match[1]}-inch"
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

    def visible_condition(text)
      return "open_box" if text.match?(/\bopen\s+box\b/i)
      return "refurbished" if text.match?(/\b(?:refurbished|renewed|certified pre-owned)\b/i)
      return "used" if text.match?(/\bused\b/i)
      return "new" if text.match?(/\bnew\b/i)

      nil
    end

    def visible_availability(text)
      return "out_of_stock" if text.match?(/\b(?:not\s+in\s*stock|out\s*of\s*stock|unavailable|sold\s+out)\b/i)
      return "in_stock" if text.match?(/\b(?:in\s*stock|add\s+to\s+cart)\b/i)

      nil
    end

    def inventory_availability(hash)
      inventory = first_present(hash["inventory_quantity"], hash["inventoryQuantity"])
      return nil if inventory.nil?

      inventory.to_i.positive? ? "in_stock" : "out_of_stock"
    end

    def inferred_brand(text)
      "Apple" if text.to_s.match?(/\bApple\b|MacBook/i)
    end

    def default_condition(source)
      "new" if source["extractor"] == "apple_ca_product_page"
    end

    def default_seller(source)
      return "Apple Canada" if source["extractor"] == "apple_ca_product_page"

      case source["retailer"].to_s
      when "jumpplus"
        "JumpPlus"
      when "owc_macsales"
        "OWC MacSales"
      when "newegg_ca"
        "Newegg Canada"
      when "cdw_ca"
        "CDW Canada"
      when "reebelo_ca"
        "Reebelo Canada"
      end
    end

    def default_brand(source)
      "Apple" if source["extractor"] == "apple_ca_product_page"
    end

    def default_currency(source)
      return "USD" if source["retailer"].to_s == "owc_macsales"

      "CAD" if source["expected_country"] == "CA" || source["url"].to_s.match?(/\.ca(?:\/|\z)/)
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
      generic_product = generic_product(body, source)
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

    def generic_product(body, source)
      ProductPageExtractor.extract_product(body, source)
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
