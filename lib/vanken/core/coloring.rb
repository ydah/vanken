# frozen_string_literal: true
# rbs_inline: enabled

require "yaml"
require "tempfile"
require "fileutils"
require_relative "display_filter/compiler"

module Vanken
  module Core
    module Coloring
      Rule = Data.define(
        :name, #: String
        :filter, #: String
        :light, #: Hash[String, String]
        :dark, #: Hash[String, String]
        :enabled, #: bool
        :program #: DisplayFilter::Program
      )

      class RuleSet
        DEFAULT_PATH = File.expand_path("../../../data/coloring_rules.yml", __dir__)
        attr_reader :rules #: Array[Rule]

        # @rbs (Hash[String, untyped] payload, ?catalog: untyped) -> void
        def initialize(payload, catalog: nil)
          raise Vanken::ConfigError, "unsupported coloring rules schema" unless payload.is_a?(Hash) && payload["schema_version"] == 1 && payload["rules"].is_a?(Array) && payload["rules"].size <= 256
          @rules = payload.fetch("rules").map do |value|
            raise Vanken::ConfigError, "invalid coloring rule" unless value.is_a?(Hash) && value["name"].is_a?(String) && value["filter"].is_a?(String) && !value["filter"].empty? && [true, false].include?(value["enabled"])
            palettes = %w[light dark].map do |theme|
              colors = value[theme]
              raise Vanken::ConfigError, "invalid rule colors" unless colors.is_a?(Hash) && %w[fg bg].all? { |key| colors[key].is_a?(String) && /\A#[\da-fA-F]{6}\z/.match?(colors[key]) }
              colors.slice("fg", "bg").transform_values { |color| color.dup.freeze }.freeze
            end
            Rule.new(value["name"].dup.freeze, value["filter"].dup.freeze, palettes[0], palettes[1], value["enabled"], DisplayFilter.compile(value["filter"], catalog: catalog))
          end.freeze
        rescue DisplayFilter::SyntaxError => error
          raise Vanken::ConfigError, "invalid coloring filter: #{error.message}"
        end

        # @rbs (_FilterView view, ?theme: Symbol) -> Hash[Symbol, String]?
        def match(view, theme: :light)
          rule = @rules.find { |item| item.enabled && item.program.match?(view) }
          return nil unless rule
          palette = theme == :light ? rule.light : rule.dark
          colors = {foreground: palette.fetch("fg")}
          colors[:background] = palette.fetch("bg") unless theme == :high_contrast
          colors
        end

        # @rbs () -> Hash[String, untyped]
        def to_h
          {"schema_version" => 1, "rules" => @rules.map do |rule|
            {"name" => rule.name, "filter" => rule.filter, "light" => rule.light.dup, "dark" => rule.dark.dup, "enabled" => rule.enabled}
          end}
        end

        # @rbs (String path) -> void
        def save(path)
          directory = File.dirname(File.expand_path(path))
          FileUtils.mkdir_p(directory, mode: 0o700)
          temporary = Tempfile.create(["coloring-", ".tmp"], directory)
          temporary.write(YAML.dump(to_h))
          temporary.flush
          temporary.fsync
          temporary.close
          File.rename(temporary.path, path)
        ensure
          temporary&.close unless temporary&.closed?
          File.unlink(temporary.path) if temporary && File.exist?(temporary.path)
        end

        # @rbs (String path, ?catalog: untyped) -> RuleSet
        def self.load(path, catalog: nil)
          raise Vanken::ConfigError, "coloring rules file exceeds 1 MiB" if File.size(path) > 1 << 20
          new(YAML.safe_load(File.read(path), permitted_classes: [], aliases: false), catalog: catalog)
        rescue Psych::Exception, SystemCallError => error
          raise Vanken::ConfigError, error.message
        end

        # @rbs (?catalog: untyped) -> RuleSet
        def self.defaults(catalog: nil) = load(DEFAULT_PATH, catalog: catalog)
      end
    end
  end
end
