# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "config_validator"
require_relative "monitor_state"

module PriceSentinel
  class NotificationError < StandardError; end

  NotificationSummary = Struct.new(:sent_count, :state_path, keyword_init: true)

  module Notifications
    DEFAULT_NOTIFY_ON = {
      "hits" => true,
      "errors" => true,
      "uncertain" => false,
      "blocked" => false,
      "scan_summary" => false
    }.freeze

    DEFAULT_NOTIFY_WHEN = %w[
      first_hit_for_check_source
      price_drops
      reentered_hit_state
    ].freeze

    module_function

    def deliver(config_path, report)
      config = MonitorState.load_config(config_path)
      alerts = config["alerts"]
      return NotificationSummary.new(sent_count: 0, state_path: nil) unless alerts.is_a?(Hash) && ConfigValidator.enabled?(alerts)

      state_path = MonitorState.alert_state_path(config_path)
      state = read_state(state_path)
      transports = enabled_ntfy_transports(alerts)
      return NotificationSummary.new(sent_count: 0, state_path: nil) if transports.empty?

      sent_count = notification_candidates(alerts, report, state).sum do |candidate|
        transports.each { |transport| post_ntfy(transport, candidate, report) }
        transports.length
      end

      write_state(state_path, next_state(state, report))
      NotificationSummary.new(sent_count: sent_count, state_path: state_path)
    end

    def enabled_ntfy_transports(alerts)
      Array(alerts["transports"]).select do |transport|
        transport.is_a?(Hash) && ConfigValidator.enabled?(transport) && transport["type"] == "ntfy"
      end
    end

    def notification_candidates(alerts, report, state)
      policy = notify_on(alerts)
      candidates = []
      candidates.concat(hit_candidates(alerts, report, state)) if policy["hits"]
      candidates.concat(report.errors.map { |result| candidate("error", result) }) if policy["errors"]
      candidates.concat(report.uncertain_findings.map { |result| candidate("uncertain", result) }) if policy["uncertain"]
      candidates.concat(report.blocked_sources.map { |result| candidate("blocked", result) }) if policy["blocked"]
      candidates << candidate("scan_summary", nil) if policy["scan_summary"]
      candidates
    end

    def hit_candidates(alerts, report, state)
      return report.target_price_hits.map { |result| candidate("hit", result) } unless dedupe_enabled?(alerts)

      report.target_price_hits.each_with_object([]) do |result, candidates|
        previous = state.fetch("sources", {})[source_key(result)]
        reason = hit_reason(alerts, previous, result)
        candidates << candidate("hit", result, reason: reason) if reason
      end
    end

    def hit_reason(alerts, previous, result)
      notify_when = notify_when(alerts)
      return "first_hit_for_check_source" if first_hit?(previous) && notify_when.include?("first_hit_for_check_source")
      return "reentered_hit_state" if previous && previous["ever_hit"] == true && previous["hit"] != true &&
                                      notify_when.include?("reentered_hit_state")
      return "price_drops" if previous && previous["hit"] == true && price_drop?(alerts, previous["price"], result.price) &&
                              notify_when.include?("price_drops")

      nil
    end

    def first_hit?(previous)
      previous.nil? || previous["ever_hit"] != true
    end

    def notify_on(alerts)
      configured = alerts["notify_on"].is_a?(Hash) ? alerts["notify_on"] : {}
      DEFAULT_NOTIFY_ON.merge(configured)
    end

    def dedupe_enabled?(alerts)
      dedupe = alerts["dedupe"]
      return true unless dedupe.is_a?(Hash)

      dedupe.fetch("enabled", true)
    end

    def notify_when(alerts)
      configured = alerts.dig("dedupe", "notify_when")
      return DEFAULT_NOTIFY_WHEN unless configured.is_a?(Array) && !configured.empty?

      configured
    end

    def price_drop?(alerts, previous_price, current_price)
      return false unless previous_price.is_a?(Hash) && current_price.is_a?(Hash)
      return false unless previous_price["currency"] == current_price["currency"]

      threshold = Float(alerts.dig("dedupe", "price_drop_threshold", "amount") || 0)
      current_amount = Float(current_price["amount"])
      previous_amount = Float(previous_price["amount"])
      return current_amount < previous_amount unless threshold.positive?

      current_amount <= previous_amount - threshold
    rescue ArgumentError, TypeError
      false
    end

    def candidate(category, result, reason: nil)
      {
        "category" => category,
        "result" => result,
        "reason" => reason
      }
    end

    def post_ntfy(transport, candidate, report)
      uri = ntfy_uri(transport)
      request = Net::HTTP::Post.new(uri)
      request.body = render_template(message_template(transport, candidate), report, candidate)
      apply_header(request, "Title", render_template(title_template(transport, candidate), report, candidate))
      apply_header(request, "Priority", transport["priority"])
      apply_header(request, "Tags", transport["tags"].nil? ? nil : Array(transport["tags"]).join(","))
      apply_header(request, "Click", transport["click"])
      apply_header(request, "Authorization", bearer_token(transport))

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      raise NotificationError, "ntfy notification failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response
    rescue NotificationError
      raise
    rescue StandardError => e
      transport_id = transport["id"] || "<missing id>"
      raise NotificationError, "ntfy transport #{transport_id} failed: #{e.message}"
    end

    def ntfy_uri(transport)
      server = transport.fetch("server").to_s.sub(%r{/+\z}, "")
      topic = URI.encode_www_form_component(transport.fetch("topic").to_s)
      URI("#{server}/#{topic}")
    end

    def title_template(transport, candidate)
      transport["title_template"] || default_title(candidate)
    end

    def message_template(transport, candidate)
      transport["message_template"] || default_message(candidate)
    end

    def default_title(candidate)
      case candidate["category"]
      when "hit"
        "Price Sentinel target-price hit"
      when "scan_summary"
        "Price Sentinel scan summary"
      else
        "Price Sentinel #{candidate["category"]}"
      end
    end

    def default_message(candidate)
      return "Scan complete: {{run_id}}" if candidate["category"] == "scan_summary"

      "{{check.id}}/{{source.id}} {{result.state}} {{price.currency}} {{price.amount}}"
    end

    def render_template(template, report, candidate)
      template.to_s.gsub(/\{\{\s*([^}]+?)\s*\}\}/) do
        template_value(Regexp.last_match(1), report, candidate).to_s
      end
    end

    def template_value(name, report, candidate)
      result = candidate["result"]
      case name
      when "run_id" then report.run_id
      when "category" then candidate["category"]
      when "reason" then candidate["reason"]
      when "check.id" then result&.check_id
      when "check.product_name" then result&.check_product_name
      when "source.id" then result&.source_id
      when "source.retailer" then result&.source_retailer
      when "source.url" then result&.source_url
      when "result.state" then result&.state
      when "result.message" then result&.message
      when "price.currency" then result&.price&.fetch("currency", nil)
      when "price.amount" then result&.price&.fetch("amount", nil)
      else
        ""
      end
    end

    def apply_header(request, name, value)
      request[name] = value.to_s unless value.nil? || value.to_s.empty?
    end

    def bearer_token(transport)
      env_name = transport["token_env"]
      return nil unless env_name && ENV[env_name]

      "Bearer #{ENV.fetch(env_name)}"
    end

    def read_state(path)
      return { "sources" => {} } unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      { "sources" => {} }
    end

    def write_state(path, state)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(state)}\n")
    end

    def next_state(state, report)
      sources = state.fetch("sources", {}).dup
      report.results.each do |result|
        previous = sources[source_key(result)] || {}
        sources[source_key(result)] = {
          "state" => result.state,
          "hit" => result.target_price_hit?,
          "ever_hit" => previous["ever_hit"] == true || result.target_price_hit?,
          "price" => result.price,
          "message" => result.message,
          "updated_at" => Time.now.utc.iso8601
        }
      end
      state.merge(
        "updated_at" => Time.now.utc.iso8601,
        "sources" => sources
      )
    end

    def source_key(result)
      "#{result.check_id}/#{result.source_id}"
    end
  end
end
