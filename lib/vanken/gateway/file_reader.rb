# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"
require "stringio"
require "io/wait"

module Vanken
  module Gateway
    class FileReader
      include Enumerable #[Core::Frame]
      QUEUED_BYTE_LIMIT = 64 << 20 #: Integer
      class BufferedInput
        # @rbs (IO input) -> void
        def initialize(input)
          @input, @buffer, @stopped = input, StringIO.new("".b), false
          @input.binmode
        end

        # @rbs (Integer length) -> String?
        def read(length)
          return "".b if length.zero?
          until @stopped
            part = @buffer.read(length)
            return part if part && !part.empty?

            part = @input.read_nonblock(65_536, exception: false)
            case part
            when String then @buffer.string = part
            when :wait_readable then @input.wait_readable(0.05)
            else return nil
            end
          end
          nil
        end

        # @rbs () -> void
        def stop = (@stopped = true)
      end
      private_constant :BufferedInput, :QUEUED_BYTE_LIMIT

      # @rbs (String | IO | StringIO input) -> void
      def initialize(input)
        io = input == "-" ? $stdin : input
        @buffered_input = nil #: BufferedInput?
        @packets = nil #: Thread::SizedQueue[Redhound::Packet | StandardError]?
        @pump = nil #: Thread?
        @budget_mutex, @budget_available, @queued_bytes = Mutex.new, ConditionVariable.new, 0
        @stopped = false
        @buffered_input = BufferedInput.new(io) if io.is_a?(IO) && !io.stat.file?
        @reader = Redhound.open(@buffered_input || input)
        @number = 0
        if @buffered_input
          # One parsed packet waiting for the byte budget can retain at most another 16 MiB.
          @packets = SizedQueue.new(256)
          @pump = Thread.new { pump_packets }
        end
      rescue Redhound::Error, IOError, SystemCallError => error
        raise Vanken::FileError, error.message
      end
      # @rbs (?timeout: Numeric?) -> Core::Frame?
      def next_frame(timeout: nil)
        return nil if @stopped
        raise ArgumentError, "timeout must be nonnegative" if timeout && timeout.negative?

        packet = @packets ? @packets.pop(timeout: timeout && Float(timeout)) : @reader.next_packet(timeout: timeout)
        raise packet if packet.is_a?(StandardError)
        return nil unless packet
        if @packets
          @budget_mutex.synchronize do
            @queued_bytes -= packet.data.bytesize
            @budget_available.signal
          end
        end
        @number += 1
        interface = packet.interface && %i[name index linktype snaplen flags mtu mac description filter].to_h { |key| [key.to_s, packet.interface.public_send(key)] }
        # Omit absent optional values; keep the declared interface metadata for saving.
        interface&.compact!
        Core::Frame.new(bytes: packet.data, timestamp_ns: packet.timestamp_ns, original_length: packet.original_length,
          linktype: packet.linktype, interface: interface, direction: packet.direction, number: @number)
      rescue Redhound::Error, IOError, SystemCallError => error
        raise Vanken::FileError, error.message
      end
      # @rbs () { (Core::Frame) -> void } -> void
      # @rbs () -> Enumerator[Core::Frame, void]
      def each
        return enum_for(:each) unless block_given?
        loop do
          packet = next_frame(timeout: 0.1)
          yield packet if packet
          break if eof?
        end
      end
      # @rbs () -> bool
      def eof? = @stopped || (@packets ? @packets.closed? && @packets.empty? : @reader.stopped?)
      # @rbs () -> void
      def stop
        @budget_mutex.synchronize do
          @stopped = true
          @budget_available.broadcast
        end
        @buffered_input&.stop
        @packets&.close
        @reader.stop
        @pump&.join
      end
      # @rbs () -> void
      def close
        stop
        @reader.close
      end
      # @rbs () -> Redhound::Capture::Stats
      def stats = @reader.stats

      private

      # @rbs () -> void
      def pump_packets
        queue = @packets
        return unless queue
        until @stopped
          packet = @reader.next_packet
          break unless packet
          break unless reserve_bytes(packet)

          queue << packet
        end
      rescue ClosedQueueError
        nil
      rescue StandardError => error
        begin
          queue << error unless @stopped
        rescue ClosedQueueError
          nil
        end
      ensure
        queue&.close
      end

      # @rbs (Redhound::Packet packet) -> bool
      def reserve_bytes(packet)
        size = packet.data.bytesize
        @budget_mutex.synchronize do
          @budget_available.wait(@budget_mutex) until @stopped || @queued_bytes + size <= QUEUED_BYTE_LIMIT
          return false if @stopped

          @queued_bytes += size
        end
        true
      end
    end
  end
end
