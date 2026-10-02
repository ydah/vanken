# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"
require_relative "../errors"

module Vanken
  module Gateway
    class FileWriter
      # @rbs (String | IO output, **untyped options) -> FileWriter
      # @rbs [T] (String | IO output, **untyped options) { (FileWriter) -> T } -> T
      def self.open(output, **options)
        writer = new(output, **options)
        return writer unless block_given?
        begin
          yield writer
        ensure
          writer.close
        end
      end
      # @rbs (String | IO output, ?format: Symbol | String, **untyped options) -> void
      def initialize(output, format: :pcapng, **options)
        @format = format.to_sym
        @interfaces = {} #: Hash[Hash[String, untyped], Redhound::Capture::Interface]
        rotating = options[:max_bytes] || options[:interval]
        if rotating
          raise ArgumentError, "ring output must be a fixed file path" unless output.is_a?(String) && output != "-" && !output.include?("%")
          count = options.fetch(:file_count, 10)
          raise ArgumentError, "ring file count must be between 1 and 1000" unless count.is_a?(Integer) && count.between?(1, 1000)
          %i[max_bytes interval].each do |key|
            value = options[key]
            raise ArgumentError, "#{key} must be positive" if value && (!value.is_a?(Numeric) || !value.finite? || !value.positive?)
          end
          options = options.merge(file_count: count)
          # The public Writer cycles slots when max_bytes is present, also for time-based rings.
          options[:max_bytes] ||= 9_223_372_036_854_775_807
          extension = File.extname(output)
          stem = output.delete_suffix(extension)
          count.times do |index|
            path = "#{stem}_#{format('%05d', index)}#{extension}"
            next unless File.exist?(path) || File.symlink?(path)
            File.open(path, File::RDWR | File::NOFOLLOW) do |file|
              raise ArgumentError, "ring output must be a regular, unlinked file owned by this user" unless file.stat.file? && file.stat.nlink == 1 && file.stat.uid == Process.uid
              file.chmod(0o600)
            end
          end
        elsif output.is_a?(String)
          @owned = File.open(output, "wb", 0o600)
          @owned.chmod(0o600)
        end
        @writer = Redhound::Writer.open(@owned || output, format: @format, **options)
      rescue Redhound::Error, ArgumentError, IOError, SystemCallError => error
        @owned&.close
        raise Vanken::FileError, error.message
      end
      # @rbs (Core::Frame | Redhound::Packet frame) -> self
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
      # @rbs () -> void
      def flush = @writer.flush
      # @rbs () -> Integer
      def bytes_written = @writer.bytes_written
      # @rbs (Redhound::Capture::Stats | Hash[Symbol | String, Integer] stats, ?interface: Redhound::Capture::Interface?) -> void
      def write_stats(stats, interface: nil)
        if stats.is_a?(Hash)
          values = stats.transform_keys(&:to_sym)
          stats = Redhound::Capture::Stats.new(received: values.fetch(:received, 0), dropped: values.fetch(:dropped, 0), if_dropped: values.fetch(:if_dropped, 0))
        end
        @writer.write_stats(stats, interface: interface)
      end
      # @rbs () -> void
      def close
        @writer&.close
      ensure
        @owned&.close unless @owned&.closed?
      end
    end
  end
end
