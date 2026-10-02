# frozen_string_literal: true

require "json"

module Vanken
  module Capture
    class ControlProtocol
      TYPES = %w[hello started stats warning error stopped].freeze
      MAX_LINE_BYTES = 65_536

      def initialize(io)
        @io = io
      end

      def write(type, **fields)
        raise ArgumentError, "unknown control message: #{type}" unless TYPES.include?(type.to_s)

        @io.write(JSON.generate(fields.merge(v: 1, type: type.to_s)) << "\n")
        @io.flush
      end

      def self.parse(line)
        return if line.bytesize > MAX_LINE_BYTES

        value = JSON.parse(line)
        value if value.is_a?(Hash) && value["v"] == 1 && TYPES.include?(value["type"])
      rescue JSON::ParserError, EncodingError
        nil
      end
    end
  end
end
