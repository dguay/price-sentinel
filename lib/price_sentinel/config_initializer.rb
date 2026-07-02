# frozen_string_literal: true

require "fileutils"

module PriceSentinel
  module ConfigInitializer
    TEMPLATE_DIR = File.expand_path("../../templates/starter", __dir__)
    TEMPLATES = {
      "generic-product" => "generic-product.yml",
      "macbook-canada" => "macbook-canada.yml"
    }.freeze

    module_function

    def create(template_name:, destination:)
      template_file = TEMPLATES[template_name]
      raise ConfigInitError, "unknown starter template: #{template_name}" unless template_file

      template_path = File.join(TEMPLATE_DIR, template_file)
      raise ConfigInitError, "starter template is missing: #{template_file}" unless File.file?(template_path)
      raise ConfigInitError, "config already exists: #{destination}" if File.exist?(destination)

      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(template_path, destination)
    end

    def template_names
      TEMPLATES.keys
    end
  end

  class ConfigInitError < StandardError; end
end
