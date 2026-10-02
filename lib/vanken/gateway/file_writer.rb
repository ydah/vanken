# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"
require_relative "../errors"

module Vanken
  module Gateway
    class FileWriter
      def self.open(output, **options)
        writer = new(output, **options)
        return writer unless block_given?
        begin
          yield writer
        ensure
          writer.close
        end
      end
      def initialize(output, format: :pcapng, **options)
        @format = format.to_sym
        @interfaces = {}
        if output.is_a?(String)
          @owned = File.open(output, "wb", 0o600)
          @owned.chmod(0o600)
        end
        @writer = Redhound::Writer.open(@owned || output, format: @format, **options)
      rescue Redhound::Error, IOError, SystemCallError => error
        @owned&.close
        raise Vanken::FileError, error.message
      end
      def <<(frame)
        packet = defined?(Core::Frame) && frame.is_a?(Core::Frame) ? Dissector.packet(frame, interfaces: @interfaces) : frame
        if @format == :pcap
          @linktype ||= packet.linktype
          raise Vanken::FileError, "pcap requires one link type; save as pcapng" unless packet.linktype == @linktype
        end
        @writer << packet
        self
      rescue Redhound::Error, ArgumentError, IOError, SystemCallError => error
        raise Vanken::FileError, error.message
      end
      def flush = @writer.flush
      def write_stats(stats, interface: nil)
        if stats.is_a?(Hash)
          values = stats.transform_keys(&:to_sym)
          stats = Redhound::Capture::Stats.new(received: values.fetch(:received, 0), dropped: values.fetch(:dropped, 0), if_dropped: values.fetch(:if_dropped, 0))
        end
        @writer.write_stats(stats, interface: interface)
      end
      def close
        @writer&.close
      ensure
        @owned&.close unless @owned&.closed?
      end
    end
  end
end
