# frozen_string_literal: true

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
