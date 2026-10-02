# frozen_string_literal: true
# rbs_inline: enabled

require "yaml"
require "fileutils"
require "logger"
require "tempfile"

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
        File.chmod(0o700, @directory)
        temporary = Tempfile.create(["preferences-", ".tmp"], @directory)
        temporary.write(YAML.dump(@values))
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, File.join(@directory, "preferences.yml"))
      ensure
        temporary&.close unless temporary&.closed?
        File.unlink(temporary.path) if temporary && File.exist?(temporary.path)
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
        validate_shape(DEFAULTS, @values)
        raise Vanken::ConfigError, "invalid theme" unless %w[system dark light high_contrast].include?(get("appearance.theme"))
        raise Vanken::ConfigError, "invalid font size" unless get("appearance.font_size").is_a?(Integer) && get("appearance.font_size").between?(8, 32)
        raise Vanken::ConfigError, "invalid time format" unless %w[relative absolute delta delta_displayed epoch].include?(get("packet_list.time_format"))
        raise Vanken::ConfigError, "invalid time precision" unless %w[milli micro nano].include?(get("packet_list.time_precision"))
        raise Vanken::ConfigError, "invalid history" unless history.all? { |item| item.is_a?(String) } && recent_files.all? { |item| item.is_a?(String) } && bookmarks.all? { |name, expression| name.is_a?(String) && expression.is_a?(String) }
        {"analysis.workers" => 1..32, "analysis.max_state_mib" => 1..65_536, "analysis.max_flows" => 1..10_000_000,
          "capture.snaplen" => 1..16_777_216, "capture.buffer_size" => 65_536..268_435_456,
          "packet_list.row_cache_rows" => 1..100_000, "layout.width" => 320..65_536, "layout.height" => 240..65_536}.each do |path, range|
          raise Vanken::ConfigError, "invalid #{path}" unless range.cover?(get(path))
        end
        raise Vanken::ConfigError, "invalid split ratios" unless get("layout.ratios").size == 2 && get("layout.ratios").all? { |ratio| ratio.is_a?(Numeric) && ratio.finite? && ratio.between?(0.1, 0.9) }
        columns = get("layout.columns")
        raise Vanken::ConfigError, "invalid columns" unless columns.all? { |column| column.is_a?(Hash) && %w[no time source destination protocol length info].include?(column["key"]) && column["width"].is_a?(Numeric) && column["width"].finite? && column["width"].between?(40, 4096) && [true, false].include?(column["visible"]) } && columns.map { |column| column["key"] }.uniq.size == columns.size
        raise Vanken::ConfigError, "invalid capture settings" unless %w[auto direct sudo pkexec].include?(get("capture.launcher")) && %w[auto ring socket bpf].include?(get("capture.backend")) && %w[in out inout].include?(get("capture.direction"))
      rescue NoMethodError, KeyError
        raise Vanken::ConfigError, "invalid preferences shape"
      end
      def validate_shape(default, value)
        valid = [true, false].include?(default) ? [true, false].include?(value) : value.is_a?(default.class)
        raise Vanken::ConfigError, "invalid preferences shape" unless valid
        if default.is_a?(Hash)
          default.each { |key, expected| validate_shape(expected, value.fetch(key)) }
        end
      end
    end
  end
end
