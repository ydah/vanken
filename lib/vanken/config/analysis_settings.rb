# frozen_string_literal: true

require_relative "yaml_file"

module Vanken
  module Config
    class AnalysisSettings
      def initialize(directory: Paths.config) = (@directory = directory)

      def decode_as
        value = YamlFile.read(File.join(@directory, "decode_as.yml"), default: {"rules" => []}).fetch("rules", [])
        validate_rules(value)
        value
      end

      def decode_as=(rules)
        validate_rules(rules)
        YamlFile.write(File.join(@directory, "decode_as.yml"), "rules" => rules)
      end

      def plugin_entries
        entries = YamlFile.read(File.join(@directory, "plugins.yml"), default: {"files" => []}).fetch("files", [])
        raise ConfigError, "invalid plugin list" unless entries.is_a?(Array) && entries.all? do |entry|
          entry.is_a?(Hash) && entry["path"].is_a?(String) && !entry["path"].include?("\0") &&
            [true, false].include?(entry["trusted"]) && [true, false].include?(entry["enabled"])
        end
        entries
      end
      def plugins = plugin_entries.select { |entry| entry["enabled"] && entry["trusted"] }.map { |entry| entry["path"] }
      def untrusted_plugins = plugin_entries.select { |entry| entry["enabled"] && !entry["trusted"] }.map { |entry| entry["path"] }

      def register_plugin(path)
        raise ConfigError, "invalid plugin path" unless path.is_a?(String) && !path.include?("\0") && File.file?(path)
        absolute = File.expand_path(path)
        entries = plugin_entries.reject { |entry| entry["path"] == absolute }
        entries << {"path" => absolute, "enabled" => true, "trusted" => false}
        save_plugins(entries)
      end

      def remove_plugin(path) = save_plugins(plugin_entries.reject { |entry| entry["path"] == File.expand_path(path) })

      def trust_plugins(paths)
        entries = plugin_entries
        raise ConfigError, "plugin is not registered" unless paths.all? { |path| entries.any? { |entry| entry["path"] == path } }
        entries.each { |entry| entry["trusted"] = true if paths.include?(entry["path"]) }
        save_plugins(entries)
      end

      private

      def save_plugins(entries) = YamlFile.write(File.join(@directory, "plugins.yml"), "files" => entries)
      def validate_rules(rules)
        valid = rules.is_a?(Array) && rules.all? { |rule| rule.is_a?(String) && rule.match?(/\A[a-z][a-z0-9_.]*==[^,\s]+,[a-z][a-z0-9_]*\z/i) }
        raise ConfigError, "invalid Decode As rules" unless valid
      end
    end
  end
end
