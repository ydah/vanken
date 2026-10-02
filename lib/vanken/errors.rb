# frozen_string_literal: true

module Vanken
  class Error < StandardError; end
  class FileError < Error; end
  class CaptureError < Error; end
  class ConfigError < Error; end
  class FilterError < Error; end
end
