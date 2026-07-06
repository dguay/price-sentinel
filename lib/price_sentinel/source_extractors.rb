# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"
require_relative "encoding"

module PriceSentinel
  module SourceExtractors
    SUPPORTED_NAMES = %w[
      amazon_ca_search
      apple_ca_product_page
      bestbuy_ca_search
      fake_source
      firecrawl_ebay_search
      generic_product_page
      staples_ca_search
      walmart_ca_search
    ].freeze

    module_function

    def fetch(name)
      case name
      when "fake_source"
        FakeSourceExtractor
      when "amazon_ca_search"
        AmazonCanadaSearchExtractor
      when "apple_ca_product_page"
        AppleCanadaProductPageExtractor
      when "bestbuy_ca_search"
        BestBuyCanadaSearchExtractor
      when "firecrawl_ebay_search"
        FirecrawlSearchExtractor
      when "generic_product_page"
        ProductPageExtractor
      when "staples_ca_search"
        StaplesCanadaSearchExtractor
      when "walmart_ca_search"
        WalmartCanadaSearchExtractor
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

      if blocked_body?(body) || amazon_blocked_503?(status, body)
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

    # Keyed on the Amazon error-page body itself, not config, so a mislabeled
    # source still gets 503-as-blocked handling.
    def amazon_blocked_503?(status, body)
      status == 503 &&
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
      candidates.concat(application_json_product_candidates(body, source).map { |candidate| [candidate, candidate_body(candidate)] })
      candidates.concat(javascript_product_candidates(body, source).map { |candidate| [candidate, candidate_body(candidate)] })
      candidates.concat(html_product_candidates(body, source).map { |candidate| [candidate, candidate["description"].to_s] })
      unique_candidates(candidates)
    end

    def candidate_body(candidate)
      [
        candidate["name"],
        candidate["description"],
        candidate["sku"],
        candidate["mpn"],
        offer_value(candidate, "availability"),
        offer_value(candidate, "itemCondition")
      ].compact.join(" ")
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
        "url" => first_present(hash["url"], hash["productUrl"], hash["productURL"], product_path_from_handle(hash["handle"]))
      }
    end

    def product_path_from_handle(handle)
      return nil if handle.nil? || handle.to_s.empty?

      "/products/#{handle}"
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

    # Explicit opt-in via source `price_unit: cents`. Only bare-integer prices
    # are treated as cents; decimal prices are already dollars even on cents sites.
    def cents_price_source?(hash, source)
      source["price_unit"].to_s == "cents" &&
        hash["price"].to_s.match?(/\A\d+\z/)
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
      when /open\s*box/i
        "open_box"
      when /brand\s*new/i
        "new"
      when /pre[-\s]?owned|\b(?:very\s+good|good|acceptable)\b/i
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

      first_present(source["seller_default"])
    end

    def default_brand(source)
      "Apple" if source["extractor"] == "apple_ca_product_page"
    end

    def default_currency(source)
      currency = source["currency_default"].to_s
      return currency unless currency.empty?

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

  # Shared tail for search-result extractors: pick the candidate matching
  # expected_attributes, then build the scan result from its offer data.
  module SearchResultCandidates
    module_function

    def result_from_candidates(candidates, source)
      return { "state" => "no_match", "message" => "matching product was not found" } if candidates.empty?

      product = select_product(candidates, source)
      return { "state" => "no_match", "message" => "matching product was not found" } unless product

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
        "product_url" => ProductPageExtractor.product_url(product, source),
        "observed" => ProductPageExtractor.extract_observed(product, source, product_text(product))
      }
    end

    def select_product(candidates, source)
      expected_attributes = source["expected_attributes"]
      return candidates.first unless expected_attributes.is_a?(Hash) && expected_attributes.values.any?

      candidates.find do |candidate|
        observed = ProductPageExtractor.extract_attributes(candidate, product_text(candidate), source)
        expected_attributes.all? do |name, expected_value|
          expected_value.nil? || observed[name] == expected_value
        end
      end
    end

    def product_text(product)
      [product["name"], product["description"]].compact.join(" ")
    end
  end

  module FirecrawlSearchExtractor
    API_URL_ENV = "FIRECRAWL_API_URL"
    API_KEY_ENV = "FIRECRAWL_API_KEY"
    DEFAULT_API_URL = "https://api.firecrawl.dev/v2/scrape"

    module_function

    def extract(source)
      api_key = env_value(API_KEY_ENV).to_s
      return { "state" => "error", "message" => "#{API_KEY_ENV} is required" } if api_key.empty?

      response = request_firecrawl(source, api_key)
      status = response.code.to_i
      body = ProductPageExtractor.normalize_body(response.body)

      unless status.between?(200, 299)
        return { "state" => "error", "message" => "Firecrawl request returned HTTP #{status}" }
      end

      payload = JSON.parse(body)
      return firecrawl_failure(payload) unless payload.fetch("success", false)

      data = payload.fetch("data", {})
      blocked_page = blocked_page(data.fetch("metadata", {}), source)
      return blocked_page if blocked_page

      candidates = product_candidates(data, source)
      SearchResultCandidates.result_from_candidates(candidates, source)
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      {
        "state" => "error",
        "message" => "Firecrawl request failed: #{e.class}: #{e.message}"
      }
    rescue JSON::ParserError => e
      {
        "state" => "uncertain",
        "message" => "Firecrawl response could not be parsed: #{e.message}"
      }
    end

    def request_firecrawl(source, api_key)
      uri = URI.parse(env_value(API_URL_ENV) || DEFAULT_API_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(firecrawl_request_body(source))

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 10,
        read_timeout: 120
      ) do |http|
        http.request(request)
      end
    end

    def env_value(name)
      return ENV[name].to_s if ENV.key?(name)

      dotenv_value(name)
    end

    def dotenv_value(name)
      path = File.join(Dir.pwd, ".env")
      return nil unless File.file?(path)

      File.readlines(path, chomp: true).each do |line|
        next if line.strip.empty? || line.lstrip.start_with?("#")

        key, value = line.split("=", 2)
        next unless key&.strip == name

        return unquote_env_value(value.to_s.strip)
      end

      nil
    rescue SystemCallError
      nil
    end

    def unquote_env_value(value)
      if (value.start_with?('"') && value.end_with?('"')) ||
         (value.start_with?("'") && value.end_with?("'"))
        value[1...-1]
      else
        value
      end
    end

    def firecrawl_request_body(source)
      {
        "url" => source.fetch("url"),
        # Firecrawl v2 accepts format objects for JSON extraction: { type: "json", schema: ..., prompt: ... }.
        "formats" => [
          {
            "type" => "json",
            "prompt" => extraction_prompt(source),
            "schema" => {
              "type" => "object",
              "properties" => {
                "products" => {
                  "type" => "array",
                  "items" => {
                    "type" => "object",
                    "properties" => {
                      "title" => { "type" => "string" },
                      "url" => { "type" => "string" },
                      "price_amount" => { "type" => "number" },
                      "currency" => { "type" => "string" },
                      "availability" => { "type" => "string" },
                      "condition" => { "type" => "string" },
                      "rating" => { "type" => "string" },
                      "sponsored" => { "type" => "boolean" }
                    },
                    "required" => ["title", "url"]
                  }
                }
              },
              "required" => ["products"]
            }
          }
        ],
        "onlyMainContent" => true,
        "location" => {
          "country" => source["expected_country"] || "CA",
          "languages" => ["en-CA", "en"]
        },
        "timeout" => source["firecrawl_timeout"] || 120_000,
        "removeBase64Images" => true,
        "blockAds" => true
      }
    end

    def extraction_prompt(source)
      product_hint = ProductPageExtractor.first_present(source["product_name"], expected_attributes_text(source))
      product_scope = product_hint ? " matching #{product_hint}" : ""
      "Extract the #{site_label(source)} search results#{product_scope}. " \
        "Return product title, product URL, price amount, currency, availability text, " \
        "condition text, rating text, and whether the result is sponsored. Include only actual product listings, " \
        "not navigation or store ads."
    end

    def site_label(source)
      host = URI.parse(source["url"].to_s).host.to_s.sub(/\Awww\./, "")
      host.empty? ? "retailer" : host
    end

    def expected_attributes_text(source)
      attributes = source["expected_attributes"]
      return nil unless attributes.is_a?(Hash)

      attributes.values.compact.join(" ")
    end

    def firecrawl_failure(payload)
      message = payload["error"] || payload["message"] || "Firecrawl request was not successful"
      { "state" => "error", "message" => message }
    end

    def blocked_page(metadata, _source)
      status = metadata["statusCode"].to_i
      if ProductPageExtractor::BLOCKED_HTTP_STATUSES.include?(status)
        return { "state" => "blocked", "message" => "Firecrawl page returned HTTP #{status}" }
      end

      if ProductPageExtractor.amazon_blocked_503?(status, metadata["title"].to_s)
        return { "state" => "blocked", "message" => "Firecrawl page returned HTTP #{status} access barrier" }
      end

      nil
    end

    def product_candidates(data, source)
      Array(data.dig("json", "products")).map do |product|
        candidate_from_product(product, source) if product.is_a?(Hash)
      end.compact
    end

    def candidate_from_product(product, source)
      title = ProductPageExtractor.first_present(product["title"], product["name"])
      price = ProductPageExtractor.first_present(product["price_amount"], product["price"])
      currency = ProductPageExtractor.first_present(product["currency"], "CAD")
      return nil unless title && price

      text = [title, product["availability"], product["rating"]].compact.join(" ")
      {
        "@type" => "Product",
        "name" => ProductPageExtractor.normalize_candidate_text(title),
        "description" => ProductPageExtractor.normalize_candidate_text(text),
        "brand" => ProductPageExtractor.inferred_brand(text),
        "offers" => {
          "@type" => "Offer",
          "price" => price,
          "priceCurrency" => currency,
          "availability" => product["availability"] || default_availability(source),
          "itemCondition" => product["condition"] || ProductPageExtractor.visible_condition(text) || "new",
          "seller" => { "name" => default_seller(source) }
        },
        "url" => product["url"]
      }
    end

    def default_availability(source)
      ProductPageExtractor.first_present(source["availability_default"])
    end

    def default_seller(source)
      ProductPageExtractor.first_present(source["seller_default"])
    end
  end

  # Amazon.ca serves complete search-result HTML to plain HTTP requests; each
  # result tile is marked with data-component-type="s-search-result", so a
  # direct fetch plus deterministic parsing replaces the former Firecrawl path.
  module AmazonCanadaSearchExtractor
    RESULT_TILE_MARKER = 'data-component-type="s-search-result"'

    module_function

    def extract(source)
      response = ProductPageExtractor.fetch_page(source.fetch("url"))
      status = response.code.to_i
      body = ProductPageExtractor.normalize_body(response.body)

      if ProductPageExtractor::BLOCKED_HTTP_STATUSES.include?(status)
        return { "state" => "blocked", "message" => "source returned HTTP #{status}" }
      end

      if ProductPageExtractor.amazon_blocked_503?(status, body)
        return { "state" => "blocked", "message" => "source returned HTTP #{status} access barrier" }
      end

      unless status.between?(200, 299)
        return { "state" => "error", "message" => "source returned HTTP #{status}" }
      end

      chunks = result_chunks(body)
      if chunks.empty?
        # A results page always carries tile markers; their absence means a
        # challenge page, a genuine zero-results page, or a layout change.
        if ProductPageExtractor.blocked_body?(body)
          return { "state" => "blocked", "message" => "source returned HTTP #{status} access barrier" }
        end

        if ProductPageExtractor.no_results_body?(body)
          return { "state" => "no_match", "message" => "matching product was not found" }
        end

        return { "state" => "uncertain", "message" => "search results could not be extracted" }
      end

      candidates = chunks.map { |chunk| candidate_from_chunk(chunk, source) }.compact
      SearchResultCandidates.result_from_candidates(candidates, source)
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      { "state" => "error", "message" => "search page request failed: #{e.class}: #{e.message}" }
    end

    def result_chunks(body)
      chunks = body.split(RESULT_TILE_MARKER)
      chunks.shift
      chunks
    end

    def candidate_from_chunk(chunk, source)
      title = ProductPageExtractor.normalize_candidate_text(
        chunk[%r{<h2[^>]*>.*?<span[^>]*>([^<]+)</span>}m, 1]
      )
      price = ProductPageExtractor.normalize_price_amount(
        chunk[/class="a-offscreen"[^>]*>\$?\s*([\d,]+\.?\d*)/, 1]
      )
      # Tiles without a visible price (no offer) are not purchasable listings.
      return nil unless title && price

      {
        "@type" => "Product",
        "name" => title,
        "brand" => ProductPageExtractor.inferred_brand(title),
        "offers" => {
          "@type" => "Offer",
          "price" => price,
          "priceCurrency" => ProductPageExtractor.default_currency(source) || "CAD",
          # "In stock." is the canonical Amazon availability text for listed
          # items with a price; unavailable items render without one.
          "availability" => source["availability_default"] || "In stock.",
          "itemCondition" => ProductPageExtractor.visible_condition(title) || "new",
          "seller" => { "name" => source["seller_default"] }
        },
        # Relative /dp/ path; SearchResultCandidates resolves it against the source url.
        "url" => chunk[%r{<a[^>]+href="(/[^"]*/dp/[^"]+)"}, 1]
      }
    end
  end

  # Walmart.ca search pages ship the full result set in the __NEXT_DATA__
  # Next.js payload, so a plain HTTP fetch is enough.
  module WalmartCanadaSearchExtractor
    module_function

    def extract(source)
      response = ProductPageExtractor.fetch_page(source.fetch("url"))
      status = response.code.to_i
      body = ProductPageExtractor.normalize_body(response.body)

      if ProductPageExtractor::BLOCKED_HTTP_STATUSES.include?(status)
        return { "state" => "blocked", "message" => "source returned HTTP #{status}" }
      end

      unless status.between?(200, 299)
        return { "state" => "error", "message" => "source returned HTTP #{status}" }
      end

      items = search_items(body)
      if items.nil?
        # PerimeterX challenge pages have no __NEXT_DATA__ result payload; a
        # generic blocked_body? check false-positives on Walmart's always-present
        # bot-detection scripts, so it only runs when the payload is missing.
        if ProductPageExtractor.blocked_body?(body)
          return { "state" => "blocked", "message" => "source returned HTTP #{status} access barrier" }
        end

        return { "state" => "uncertain", "message" => "search data could not be extracted" }
      end

      candidates = items.map { |item| candidate_from_item(item, source) }.compact
      SearchResultCandidates.result_from_candidates(candidates, source)
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      { "state" => "error", "message" => "search page request failed: #{e.class}: #{e.message}" }
    rescue JSON::ParserError => e
      { "state" => "uncertain", "message" => "search data could not be parsed: #{e.message}" }
    end

    def search_items(body)
      match = body.match(%r{<script[^>]+id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>}im)
      return nil unless match

      data = JSON.parse(match[1])
      stacks = data.dig("props", "pageProps", "initialData", "searchResult", "itemStacks")
      return nil unless stacks.is_a?(Array)

      stacks.flat_map { |stack| Array(stack["items"]) }.select { |item| item.is_a?(Hash) }
    end

    def candidate_from_item(item, source)
      name = item["name"]
      amount = price_amount(item)
      return nil unless name && amount

      {
        "@type" => "Product",
        "name" => ProductPageExtractor.normalize_candidate_text(name),
        "brand" => item["brand"] || ProductPageExtractor.inferred_brand(name),
        "sku" => item["usItemId"],
        "offers" => {
          "@type" => "Offer",
          "price" => amount,
          "priceCurrency" => ProductPageExtractor.default_currency(source) || "CAD",
          "availability" => availability(item),
          "itemCondition" => ProductPageExtractor.visible_condition(name.to_s) || "new",
          "seller" => { "name" => item["sellerName"] || source["seller_default"] }
        },
        "url" => item["canonicalUrl"]
      }
    end

    def price_amount(item)
      ProductPageExtractor.normalize_price_amount(
        item.dig("priceInfo", "linePrice").to_s.delete("$")
      )
    end

    def availability(item)
      item.dig("availabilityStatusV2", "display") ||
        item["availabilityStatus"].to_s.tr("_", " ")
    end
  end

  # Best Buy Canada's storefront blocks plain HTTP, but its public search API
  # (the one the site itself calls) returns clean JSON without a challenge.
  module BestBuyCanadaSearchExtractor
    API_PATH = "/api/v2/json/search"

    module_function

    def extract(source)
      response = fetch_json(api_url(source.fetch("url")))
      status = response.code.to_i
      body = ProductPageExtractor.normalize_body(response.body)

      if ProductPageExtractor::BLOCKED_HTTP_STATUSES.include?(status)
        return { "state" => "blocked", "message" => "source returned HTTP #{status}" }
      end

      unless status.between?(200, 299)
        return { "state" => "error", "message" => "source returned HTTP #{status}" }
      end

      payload = JSON.parse(body)
      candidates = Array(payload["products"]).map do |product|
        candidate_from_product(product, source) if product.is_a?(Hash)
      end.compact
      SearchResultCandidates.result_from_candidates(candidates, source)
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      { "state" => "error", "message" => "search API request failed: #{e.class}: #{e.message}" }
    rescue JSON::ParserError => e
      { "state" => "uncertain", "message" => "search data could not be parsed: #{e.message}" }
    end

    # Accepts the human search URL (…/search?search=term) and rewrites it to
    # the JSON API on the same host, so tests can point at a local server.
    def api_url(url)
      uri = URI.parse(url)
      return url if uri.path == API_PATH

      query = URI.decode_www_form(uri.query.to_s).to_h
      term = query["search"] || query["query"]
      raise KeyError, "search term is missing from source url" unless term

      api_uri = uri.dup
      api_uri.path = API_PATH
      api_uri.query = URI.encode_www_form("query" => term, "lang" => "en-CA")
      api_uri.to_s
    end

    def fetch_json(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "PriceSentinel/1.0"
      request["Accept"] = "application/json"

      # ponytail: BestBuy's search API intermittently stalls past read_timeout;
      # two retries clear it. Promote to a shared helper if other sources flake too.
      attempts = 0
      begin
        attempts += 1
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 10,
          read_timeout: 10
        ) do |http|
          http.request(request)
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError
        raise if attempts >= 3

        sleep(attempts)
        retry
      end
    end

    def candidate_from_product(product, source)
      name = product["name"]
      amount = ProductPageExtractor.normalize_price_amount(product["salePrice"])
      return nil unless name && amount

      {
        "@type" => "Product",
        "name" => ProductPageExtractor.normalize_candidate_text(name),
        "sku" => product["sku"],
        "brand" => ProductPageExtractor.inferred_brand(name),
        "offers" => {
          "@type" => "Offer",
          "price" => amount,
          "priceCurrency" => ProductPageExtractor.default_currency(source) || "CAD",
          # The search payload has no availability field; sources opt in via availability_default.
          "availability" => source["availability_default"],
          "itemCondition" => ProductPageExtractor.visible_condition(name.to_s) || "new",
          "seller" => { "name" => product.dig("seller", "name") || source["seller_default"] }
        },
        "url" => product["productUrl"]
      }
    end
  end

  # Staples.ca sits behind Cloudflare, but its search is Algolia-backed and the
  # search-only credentials below are public (served to every browser).
  module StaplesCanadaSearchExtractor
    ALGOLIA_URL = "https://h5yovykinu-dsn.algolia.net/1/indexes/shopify_products/query"
    ALGOLIA_APP_ID = "H5YOVYKINU"
    ALGOLIA_API_KEY = "e2b28fca7402ac2a70c0db268ac062e1"

    module_function

    def extract(source)
      query = search_query(source.fetch("url"))
      response = post_query(source, query)
      status = response.code.to_i
      body = ProductPageExtractor.normalize_body(response.body)

      unless status.between?(200, 299)
        return { "state" => "error", "message" => "search API returned HTTP #{status}" }
      end

      hits = Array(JSON.parse(body)["hits"])
      candidates = hits.map do |hit|
        candidate_from_hit(hit, source) if hit.is_a?(Hash)
      end.compact
      SearchResultCandidates.result_from_candidates(candidates, source)
    rescue KeyError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
      { "state" => "error", "message" => "search API request failed: #{e.class}: #{e.message}" }
    rescue JSON::ParserError => e
      { "state" => "uncertain", "message" => "search data could not be parsed: #{e.message}" }
    end

    def search_query(url)
      uri = URI.parse(url)
      query = URI.decode_www_form(uri.query.to_s).to_h
      term = query["query"] || query["q"]
      raise KeyError, "search term is missing from source url" unless term

      term
    end

    # search_api_url override lets tests point at a local server.
    def post_query(source, query)
      uri = URI.parse(source["search_api_url"] || ALGOLIA_URL)
      request = Net::HTTP::Post.new(uri)
      request["x-algolia-application-id"] = ALGOLIA_APP_ID
      request["x-algolia-api-key"] = ALGOLIA_API_KEY
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(
        "query" => query,
        "hitsPerPage" => 30,
        "filters" => 'tags:"en_CA"'
      )

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

    def candidate_from_hit(hit, source)
      title = hit["title"]
      amount = ProductPageExtractor.normalize_price_amount(hit["price"])
      return nil unless title && amount

      {
        "@type" => "Product",
        "name" => ProductPageExtractor.normalize_candidate_text(title),
        "sku" => hit["sku"],
        "brand" => ProductPageExtractor.inferred_brand(title),
        "offers" => {
          "@type" => "Offer",
          "price" => amount,
          "priceCurrency" => ProductPageExtractor.default_currency(source) || "CAD",
          "availability" => hit["inventory_available"] ? "in_stock" : "out_of_stock",
          "itemCondition" => ProductPageExtractor.visible_condition(title.to_s) || "new",
          "seller" => { "name" => source["seller_default"] }
        },
        "url" => product_url(hit)
      }
    end

    def product_url(hit)
      handle = hit["handle"].to_s
      return nil if handle.empty?

      "/products/#{handle}"
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
