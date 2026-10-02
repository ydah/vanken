# frozen_string_literal: true

require "yaml"
require "tempfile"
require "fileutils"

module Vanken
  module Config
    module YamlFile
      def self.read(path, default: {})
        return default unless File.file?(path)
        raise ConfigError, "configuration exceeds 1 MiB" if File.size(path) > 1 << 20
        value = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        raise ConfigError, "unsupported configuration schema: #{path}" unless value.is_a?(Hash) && value["schema_version"] == 1
        value
      rescue Psych::Exception => error
        raise ConfigError, error.message
      end

      def self.write(path, value)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        temporary = Tempfile.create(["vanken-", ".yml"], directory)
        temporary.chmod(0o600)
        temporary.write(YAML.dump(value.merge("schema_version" => 1)))
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary&.close unless temporary&.closed?
        File.unlink(temporary.path) if temporary && File.exist?(temporary.path)
      end
    end
  end
end
