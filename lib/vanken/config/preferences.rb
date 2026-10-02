# frozen_string_literal: true
# rbs_inline: enabled

require "yaml"
require "fileutils"
require "logger"

module Vanken
  module Config
    module Paths
      def self.config
        case RUBY_PLATFORM
        when /darwin/ then File.join(Dir.home, "Library", "Application Support", "Vanken")
        when /mingw|mswin/ then File.join(ENV.fetch("APPDATA", Dir.home), "Vanken")
        else File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")), "vanken")
        end
      end
      def self.state
        return File.join(config, "state") unless RUBY_PLATFORM.include?("linux")
        File.join(ENV.fetch("XDG_STATE_HOME", File.join(Dir.home, ".local", "state")), "vanken")
      end
    end

    class Preferences
      DEFAULTS = {
        "schema_version" => 1,
        "appearance" => {"theme" => "system", "font_size" => 13, "language" => "ja"},
        "packet_list" => {"time_format" => "relative", "time_precision" => "micro", "autoscroll" => true, "row_cache_rows" => 20_000},
        "capture" => {"snaplen" => 262_144, "promiscuous" => true, "buffer_size" => 4 << 20, "backend" => "auto", "launcher" => "auto", "direction" => "inout"},
        "analysis" => {"verify_checksums" => false, "max_state_mib" => 256, "max_flows" => 100_000, "workers" => 4},
        "history" => [], "recent_files" => [], "bookmarks" => {}, "layout" => {"ratios" => [0.55, 0.6], "width" => 1280, "height" => 800, "columns" => []}
      }.freeze
      attr_reader :warning, :directory

      def initialize(directory: Paths.config)
        @directory = directory
        @values = Marshal.load(Marshal.dump(DEFAULTS))
        path = File.join(directory, "preferences.yml")
        return unless File.file?(path)
        saved = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        raise Vanken::ConfigError, "unsupported preferences schema" unless saved.is_a?(Hash) && saved["schema_version"] == 1
        merge(@values, saved)
        validate
      rescue Psych::Exception, Vanken::ConfigError, SystemCallError, TypeError => error
        @values = Marshal.load(Marshal.dump(DEFAULTS))
        @warning = error.message
      end

      def get(path) = path.split(".").reduce(@values) { |value, key| value.fetch(key) }
      def set(path, value)
        keys = path.split(".")
        target = keys[0...-1].reduce(@values) { |hash, key| hash.fetch(key) }
        previous = target.fetch(keys.last)
        target[keys.last] = value
        validate
        save
        value
      rescue Vanken::ConfigError
        target[keys.last] = previous
        raise
      end
      def history = @values["history"].dup
      def recent_files = @values["recent_files"].dup
      def bookmarks = @values["bookmarks"].dup
      def remember_filter(expression) = remember("history", expression, 50)
      def remember_file(path) = remember("recent_files", File.expand_path(path), 10)
      def bookmark(name, expression)
        @values["bookmarks"][name] = expression
        save
      end
      def save
        FileUtils.mkdir_p(@directory, mode: 0o700)
        temporary = File.join(@directory, "preferences-#{Process.pid}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |io| io.write(YAML.dump(@values)); io.flush; io.fsync }
        File.rename(temporary, File.join(@directory, "preferences.yml"))
      ensure
        File.unlink(temporary) if temporary && File.exist?(temporary)
      end

      private

      def remember(key, value, limit)
        @values[key] = ([value] + @values[key].reject { |entry| entry == value }).first(limit)
        save
      end
      def merge(base, saved)
        saved.each do |key, value|
          next unless base.key?(key)
          key == "bookmarks" || !base[key].is_a?(Hash) || !value.is_a?(Hash) ? base[key] = value : merge(base[key], value)
        end
      end
      def validate
        raise Vanken::ConfigError, "invalid theme" unless %w[system dark light high_contrast].include?(get("appearance.theme"))
        raise Vanken::ConfigError, "invalid font size" unless get("appearance.font_size").is_a?(Integer) && get("appearance.font_size").between?(8, 32)
        raise Vanken::ConfigError, "invalid time format" unless %w[relative absolute delta delta_displayed epoch].include?(get("packet_list.time_format"))
        raise Vanken::ConfigError, "invalid history" unless history.all? { |item| item.is_a?(String) } && recent_files.all? { |item| item.is_a?(String) } && bookmarks.is_a?(Hash)
      rescue NoMethodError, KeyError
        raise Vanken::ConfigError, "invalid preferences shape"
      end
    end
  end
end
