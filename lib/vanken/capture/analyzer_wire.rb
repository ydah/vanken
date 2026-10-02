# frozen_string_literal: true

require "io/wait"

module Vanken
  module Capture
    # These pipes are private to the same-user worker. Marshal.load only receives
    # protocol messages serialized by our child, never an external serialized object.
    module AnalyzerWire
      VERSION = 1
      MAX_BYTES = 64 << 20
      def self.write(io, value)
        bytes = Marshal.dump(value.merge(version: VERSION))
        raise Vanken::Error, "analysis message exceeds limit" if bytes.bytesize > MAX_BYTES
        io.write([bytes.bytesize].pack("L>"))
        io.write(bytes)
        io.flush
      end
      def self.read(io, cancelled: nil)
        header = exact(io, 4, cancelled)
        length = header.unpack1("L>")
        raise Vanken::Error, "invalid analysis message size" unless length.between?(1, MAX_BYTES)
        value = Marshal.load(exact(io, length, cancelled))
        raise Vanken::Error, "invalid analysis protocol" unless value.is_a?(Hash) && value[:version] == VERSION
        value
      end
      def self.exact(io, length, cancelled)
        bytes = String.new(capacity: length, encoding: Encoding::BINARY)
        fragment = String.new(capacity: [length, 64 << 10].min, encoding: Encoding::BINARY)
        until bytes.bytesize == length
          raise Vanken::Error, "analysis stopped" if cancelled&.call
          next unless io.wait_readable(0.05)
          part = io.read_nonblock([length - bytes.bytesize, 64 << 10].min, fragment, exception: false)
          next if part == :wait_readable
          raise Vanken::Error, "analysis worker closed its pipe" unless part
          bytes << part
        end
        bytes
      end
    end
  end
end
