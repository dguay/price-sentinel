# frozen_string_literal: true

module PriceSentinel
  module Encoding
    module_function

    def normalize_body(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end
  end
end
