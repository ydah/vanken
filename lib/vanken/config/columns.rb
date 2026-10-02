# frozen_string_literal: true

require "ipaddr"
require_relative "yaml_file"

module Vanken
  module Config
    class Columns
      BUILTINS = [[:no, "No.", 64], [:time, "Time", 128], [:source, "Source", 164],
        [:destination, "Destination", 164], [:protocol, "Protocol", 90], [:length, "Length", 76], [:info, "Info", 560]].freeze

      def self.load(directory:, legacy: [])
        path = File.join(directory, "columns.yml")
        raise ConfigError, "columns configuration must not be a symlink" if File.symlink?(path)
        return new(YamlFile.read(path)) if File.file?(path)
        settings = new
        unless legacy.empty?
          ordered = settings.to_h["columns"].sort_by { |column| legacy.index { |item| item["key"] == column["key"] } || legacy.size }
          ordered.each do |column|
            saved = legacy.find { |item| item["key"] == column["key"] }
            column.merge!(saved.slice("width", "visible")) if saved
          end
          settings.replace("schema_version" => 1, "columns" => ordered)
        end
        settings
      end

      def initialize(payload = nil)
        payload ||= {"schema_version" => 1, "columns" => BUILTINS.map do |key, label, width|
          {"key" => key.to_s, "label" => label, "width" => width, "visible" => true, "field" => nil}
        end}
        replace(payload)
      end

      def replace(payload)
        raise ConfigError, "unsupported columns schema" unless payload.is_a?(Hash) && payload["schema_version"] == 1
        items = payload["columns"]
        raise ConfigError, "columns must contain between 1 and 64 entries" unless items.is_a?(Array) && items.size.between?(1, 64)
        rows = items.map do |item|
          raise ConfigError, "invalid column" unless item.is_a?(Hash)
          key, label, width, visible, field = item.values_at("key", "label", "width", "visible", "field")
          custom = self.class.valid_field?(field) && key == "field:#{field}"
          builtin = field.nil? && BUILTINS.any? { |entry| entry.first.to_s == key }
          raise ConfigError, "invalid column key or field" unless key.is_a?(String) && (custom || builtin)
          raise ConfigError, "invalid column label" unless label.is_a?(String) && !label.empty? && label.bytesize <= 256 && !label.include?("\0")
          raise ConfigError, "invalid column width or visibility" unless width.is_a?(Numeric) && width.finite? && width.between?(40, 4096) && [true, false].include?(visible)
          {"key" => key.dup.freeze, "label" => label.dup.freeze, "width" => width, "visible" => visible, "field" => field&.dup&.freeze}.freeze
        end
        raise ConfigError, "duplicate columns" unless rows.map { |item| item["key"] }.uniq.size == rows.size
        @columns = rows.freeze
        self
      end

      def self.valid_field?(field)
        field.is_a?(String) && field.bytesize <= 256 && /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+\z/.match?(field)
      end

      def to_h = {"schema_version" => 1, "columns" => @columns.map(&:dup)}
      def custom = @columns.select { |column| column["field"] }
      def table_columns
        @columns.map do |column|
          key = column.fetch("key").to_sym
          {key: key, label: column.fetch("label"), width: column.fetch("width"), visible: column.fetch("visible"),
           align: %i[no time length].include?(key) ? :end : :start}
        end
      end

      def add(field, label: field, width: 120)
        raise ConfigError, "invalid custom field name" unless self.class.valid_field?(field)
        key = "field:#{field}"
        rows = to_h["columns"]
        existing = rows.find { |item| item["key"] == key }
        if existing
          existing["visible"] = true
        else
          rows << {"key" => key, "label" => label, "width" => width, "visible" => true, "field" => field}
        end
        replace("schema_version" => 1, "columns" => rows)
        key
      end

      def remove(key)
        raise ConfigError, "hide builtin columns instead of removing them" unless custom.any? { |item| item["key"] == key.to_s }
        replace("schema_version" => 1, "columns" => to_h["columns"].reject { |item| item["key"] == key.to_s })
      end

      def move(key, index)
        rows = to_h["columns"]
        raise ConfigError, "column position is outside the list" unless index.is_a?(Integer) && index.between?(0, rows.size - 1)
        item = rows.find { |column| column["key"] == key.to_s } || raise(ConfigError, "unknown column")
        rows.delete(item)
        rows.insert(index, item)
        replace("schema_version" => 1, "columns" => rows)
      end

      def update_layout(items)
        rows = items.map do |item|
          key = item.fetch(:key).to_s
          saved = @columns.find { |column| column["key"] == key } || raise(ConfigError, "unknown column")
          saved.merge("width" => item.fetch(:width), "visible" => item.fetch(:visible))
        end
        raise ConfigError, "column layout is incomplete" unless rows.size == @columns.size
        replace("schema_version" => 1, "columns" => rows)
      rescue KeyError, NoMethodError
        raise ConfigError, "invalid column layout"
      end

      def save(directory)
        path = File.join(directory, "columns.yml")
        raise ConfigError, "columns configuration must not be a symlink" if File.symlink?(directory) || File.symlink?(path)
        YamlFile.write(path, to_h)
      end

      def self.display(values, type: nil)
        # ponytail: cap a cell at 16 values and 4096 bytes; the details and byte panes retain full data.
        text = values.first(16).map do |value|
          text = type == :bytes && value.is_a?(String) ? value.byteslice(0, 1024).unpack1("H*") : value.to_s.byteslice(0, 1024)
          escaped = text.b.gsub(/[^\x20-\x7e]/n) { |byte| format("\\x%02x", byte.getbyte(0)) }
          escaped += "…" if value.to_s.bytesize > 1024
          escaped
        end.join(", ")
        text = text.byteslice(0, 4096).force_encoding(Encoding::UTF_8).scrub + "…" if text.bytesize > 4096 || values.size > 16
        text
      end

      def self.sort_value(value, type: nil)
        return [2, 0] if value.nil?
        return [0, value] if value.is_a?(Numeric)
        return [0, value ? 1 : 0] if [true, false].include?(value)
        return [0, IPAddr.new(value.to_s).ipv4? ? 4 : 6, IPAddr.new(value.to_s).to_i] if type == :address
        return [0, value.to_s.delete(".:-").to_i(16)] if type == :mac
        [1, value.to_s.b]
      rescue ArgumentError
        [1, value.to_s.b]
      end
    end
  end
end
