# frozen_string_literal: true

require "yaml"
require_relative "config_validator"
require_relative "source_extractors"

module PriceSentinel
  ScanReport = Struct.new(:config_path, :results, keyword_init: true) do
    def checks_scanned
      results.map(&:check_id).uniq.length
    end

    def sources_scanned
      results.length
    end

    def target_price_hits
      results.select(&:target_price_hit?)
    end

    def blocked_sources
      results.select { |result| result.state == "blocked" }
    end

    def uncertain_findings
      results.select { |result| result.state == "uncertain" }
    end

    def errors
      results.select { |result| result.state == "error" }
    end
  end

  ScanSourceResult = Struct.new(
    :check_id,
    :source_id,
    :state,
    :price,
    :message,
    :constraints_passed,
    keyword_init: true
  ) do
    def target_price_hit?
      state == "found" && constraints_passed
    end
  end

  module Scanner
    module_function

    def scan_file(path)
      validation = ConfigValidator.validate_file(path)
      raise InvalidConfigError, validation.errors unless validation.valid?

      config = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      enabled_checks = Array(config["checks"]).select { |check| ConfigValidator.enabled?(check) }
      results = enabled_checks.flat_map do |check|
        Array(check["sources"]).select { |source| ConfigValidator.enabled?(source) }.map do |source|
          scan_source(check, source)
        end
      end

      ScanReport.new(config_path: path, results: results)
    end

    def scan_source(check, source)
      extraction = SourceExtractors.fetch(source["extractor"]).extract(source)
      state = extraction.fetch("state")
      price = extraction["price"]
      constraints_passed = false

      if state == "found"
        constraints_passed = price_at_or_below_target?(price, check["target"]) &&
                             product_constraints_pass?(check, price, extraction.fetch("observed", {}))
      end

      ScanSourceResult.new(
        check_id: check.fetch("id"),
        source_id: source.fetch("id"),
        state: state,
        price: price,
        message: extraction["message"],
        constraints_passed: constraints_passed
      )
    rescue ArgumentError => e
      ScanSourceResult.new(
        check_id: check.fetch("id"),
        source_id: source.fetch("id"),
        state: "error",
        price: nil,
        message: e.message,
        constraints_passed: false
      )
    end

    def price_at_or_below_target?(price, target)
      return false unless price.is_a?(Hash) && target.is_a?(Hash)
      return false unless price["currency"] == target["currency"]

      Float(price["amount"]) <= Float(target["amount"])
    rescue ArgumentError, TypeError
      false
    end

    def product_constraints_pass?(check, price, observed)
      required = check.fetch("required", {})

      currency_matches?(required, price) &&
        allowed_value_matches?(required.dig("condition", "allow"), observed["condition"]) &&
        allowed_value_matches?(required.dig("seller", "allow"), observed["seller"]) &&
        allowed_value_matches?(required.dig("availability", "allow"), observed["availability"]) &&
        scalar_constraint_matches?(required["ships_to"], observed["ships_to"]) &&
        product_attributes_match?(check.fetch("attributes", {}), observed.fetch("attributes", {}))
    end

    def currency_matches?(required, price)
      !required.key?("currency") || price["currency"] == required["currency"]
    end

    def allowed_value_matches?(allowed, observed_value)
      return true unless allowed.is_a?(Array) && !allowed.empty?

      allowed.include?(observed_value)
    end

    def scalar_constraint_matches?(required_value, observed_value)
      required_value.nil? || required_value == observed_value
    end

    def product_attributes_match?(expected_attributes, observed_attributes)
      return true unless expected_attributes.is_a?(Hash)
      return true if expected_attributes.values.all?(&:nil?)
      return false unless observed_attributes.is_a?(Hash)

      expected_attributes.all? do |name, expected_value|
        expected_value.nil? || observed_attributes[name] == expected_value
      end
    end
  end

  class InvalidConfigError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.join(", "))
    end
  end
end
