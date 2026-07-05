# frozen_string_literal: true

require "yaml"
require "uri"
require_relative "source_extractors"

module PriceSentinel
  ValidationResult = Struct.new(:errors, :enabled_checks, :enabled_sources, keyword_init: true) do
    def valid?
      errors.empty?
    end
  end

  module ConfigValidator
    SUPPORTED_EXTRACTORS = SourceExtractors::SUPPORTED_NAMES

    module_function

    def validate_file(path)
      config = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      return invalid_result(["config root must be a mapping"]) unless config.is_a?(Hash)

      checks = Array(config["checks"])
      shape_errors = validate_shape(config, checks)
      return invalid_result(shape_errors) unless shape_errors.empty?

      enabled_checks = checks.select { |check| enabled?(check) }
      enabled_sources = enabled_checks.flat_map { |check| Array(check["sources"]) }.select { |source| enabled?(source) }
      errors = validate_alerts(config["alerts"])
      errors.concat(enabled_checks.flat_map { |check| validate_enabled_check(check) })

      ValidationResult.new(
        errors: errors,
        enabled_checks: enabled_checks.length,
        enabled_sources: enabled_sources.length
      )
    rescue Psych::Exception => e
      invalid_result(["YAML could not be parsed: #{e.message}"])
    rescue Errno::ENOENT
      invalid_result(["config file does not exist"])
    end

    def invalid_result(errors)
      ValidationResult.new(
        errors: errors,
        enabled_checks: 0,
        enabled_sources: 0
      )
    end

    def validate_shape(config, checks)
      errors = []

      checks.each_with_index do |check, check_index|
        unless check.is_a?(Hash)
          errors << "checks[#{check_index}] must be a mapping"
          next
        end

        Array(check["sources"]).each_with_index do |source, source_index|
          unless source.is_a?(Hash)
            errors << "checks[#{check.fetch("id", check_index)}].sources[#{source_index}] must be a mapping"
          end
        end
      end

      alerts = config["alerts"]
      if alerts.is_a?(Hash)
        Array(alerts["transports"]).each_with_index do |transport, transport_index|
          unless transport.is_a?(Hash)
            errors << "alerts.transports[#{transport_index}] must be a mapping"
          end
        end
      end

      errors
    end

    def enabled?(entry)
      entry.fetch("enabled", true)
    end

    def validate_enabled_check(check)
      errors = []
      path = "checks[#{check.fetch("id", "<missing id>")}]"
      target = check["target"]

      errors << "#{path}.target.amount is required" unless target.is_a?(Hash) && present?(target["amount"])
      errors << "#{path}.target.currency is required" unless target.is_a?(Hash) && present?(target["currency"])
      enabled_sources = Array(check["sources"]).select { |source| enabled?(source) }
      errors << "#{path}.sources must include at least one enabled source" if enabled_sources.empty?
      enabled_sources.each do |source|
        errors.concat(validate_enabled_source(path, source))
      end

      errors
    end

    def validate_enabled_source(check_path, source)
      errors = []
      path = "#{check_path}.sources[#{source.fetch("id", "<missing id>")}]"
      extractor = source["extractor"]

      unless SUPPORTED_EXTRACTORS.include?(extractor)
        errors << "#{path}.extractor is unknown: #{extractor}"
      end
      errors << "#{path}.url must be an absolute http(s) URL" unless http_url?(source["url"])

      price_unit = source["price_unit"]
      unless price_unit.nil? || %w[cents dollars].include?(price_unit)
        errors << "#{path}.price_unit must be \"cents\" or \"dollars\": #{price_unit}"
      end

      errors
    end

    def validate_alerts(alerts)
      return [] unless alerts.is_a?(Hash) && enabled?(alerts)

      Array(alerts["transports"]).select { |transport| enabled?(transport) }.flat_map do |transport|
        validate_enabled_alert_transport(transport)
      end
    end

    def validate_enabled_alert_transport(transport)
      errors = []
      path = "alerts.transports[#{transport.fetch("id", "<missing id>")}]"

      errors << "#{path}.type is unknown: #{transport["type"]}" unless transport["type"] == "ntfy"
      errors << "#{path}.topic is required" unless present?(transport["topic"])
      errors << "#{path}.server must be an absolute http(s) URL" unless http_url?(transport["server"])

      errors
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def http_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTP) && present?(uri.host)
    rescue URI::InvalidURIError
      false
    end
  end
end
