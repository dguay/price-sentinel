# frozen_string_literal: true

require "json"
require "fileutils"

module PriceSentinel
  module MarkdownLog
    module_function

    def update(path, report)
      FileUtils.mkdir_p(File.dirname(path))
      existing = File.exist?(path) ? File.read(path) : ""
      without_same_run = existing.sub(scan_report_block_pattern(report.run_id), "")
      File.write(path, "#{scan_report_block(report)}\n\n#{without_same_run.lstrip}")
    end

    def scan_report_block(report)
      lines = [
        start_marker(report.run_id),
        "## Price Sentinel Scan",
        "",
        "Run ID: `#{report.run_id}`",
        "Scanned at: `#{report.scanned_at}`",
        "",
        "### Summary",
        "",
        "- Checks scanned: #{report.checks_scanned}",
        "- Sources scanned: #{report.sources_scanned}",
        "- Target-price hits: #{report.target_price_hits.length}",
        "- Uncertain findings: #{report.uncertain_findings.length}",
        "- Blocked sources: #{report.blocked_sources.length}",
        "- Errors: #{report.errors.length}",
        "",
        result_group("Target-Price Hits", report.target_price_hits, include_product_url: true),
        result_group("Uncertain Findings", report.uncertain_findings),
        result_group("Blocked Sources", report.blocked_sources),
        result_group("Errors", report.errors),
        embedded_json(report),
        end_marker(report.run_id)
      ].flatten

      lines.join("\n")
    end

    def result_group(title, results, include_product_url: false)
      [
        "### #{title}",
        "",
        result_lines(results, include_product_url: include_product_url),
        ""
      ]
    end

    def embedded_json(report)
      return [] unless report.include_json

      [
        "### Embedded JSON",
        "",
        "```json",
        JSON.generate(report.to_h),
        "```",
        ""
      ]
    end

    def result_lines(results, include_product_url: false)
      return ["- None"] if results.empty?

      results.map do |result|
        "- `#{result.check_id}/#{result.source_id}` - #{price_text(result)}#{product_url_text(result, include_product_url)}#{message_text(result)}"
      end
    end

    def price_text(result)
      return "no price" unless result.price

      "#{result.price["currency"]} #{format("%.2f", result.price["amount"])}"
    end

    def message_text(result)
      result.message ? " - #{result.message}" : ""
    end

    def product_url_text(result, include_product_url)
      return "" unless include_product_url && result.product_url

      " - #{result.product_url}"
    end

    def start_marker(run_id)
      "<!-- price-sentinel:scan-report run_id=\"#{run_id}\" -->"
    end

    def end_marker(run_id)
      "<!-- /price-sentinel:scan-report run_id=\"#{run_id}\" -->"
    end

    def scan_report_block_pattern(run_id)
      start_pattern = Regexp.escape(start_marker(run_id))
      end_pattern = Regexp.escape(end_marker(run_id))
      /#{start_pattern}\n.*?\n#{end_pattern}\n*/m
    end
  end
end
