# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"

module Vanken
  module Gateway
    class FileReader
      include Enumerable
      def initialize(input)
        @reader = Redhound.open(input)
        @number = 0
      rescue Redhound::Error, IOError, SystemCallError => error
        raise Vanken::FileError, error.message
      end
      def next_frame(timeout: nil)
        packet = @reader.next_packet(timeout: timeout)
        return nil unless packet
        @number += 1
        interface = packet.interface && %i[name index linktype snaplen flags mtu mac description filter].to_h { |key| [key.to_s, packet.interface.public_send(key)] }
        # Omit absent optional values; keep the declared interface metadata for saving.
        interface&.compact!
        Core::Frame.new(bytes: packet.data, timestamp_ns: packet.timestamp_ns, original_length: packet.original_length,
          linktype: packet.linktype, interface: interface, direction: packet.direction, number: @number)
      rescue Redhound::Error, IOError, SystemCallError => error
        raise Vanken::FileError, error.message
      end
      def each
        return enum_for(:each) unless block_given?
        loop do
          packet = next_frame(timeout: 0.1)
          yield packet if packet
          break if eof?
        end
      end
      def eof? = @reader.stopped?
      def stop = @reader.stop
      def close = @reader.close
      def stats = @reader.stats
    end
  end
end
