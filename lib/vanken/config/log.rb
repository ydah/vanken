# frozen_string_literal: true

require "logger"
require "fileutils"

module Vanken
  module Config
    module Log
      def self.open(debug: false, directory: Paths.state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        path = File.join(directory, "vanken.log")
        File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600, &:close)
        File.chmod(0o600, path)
        Logger.new(path, 5, 1 << 20, level: debug ? Logger::DEBUG : Logger::INFO)
      end
    end
  end
end
