# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Capture
    class Receiver
      def initialize(document, source) = (@document, @source = document, source)
      def run
        flushed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        each_frame do |frame|
          break if @document.cancelled?
          number = @document.store.append(frame) if frame
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if (number && (number % 256 == 0 || number == 50)) || now - flushed_at >= 0.05
            @document.store.flush
            @document.signal
            flushed_at = now
            Thread.pass
          end
        end
      rescue StandardError => error
        @document.fail(error)
      ensure
        @document.store.flush
        @document.receiving_done
        @source.close if @source.respond_to?(:close)
      end
      private
      def each_frame
        return @source.each { |frame| yield frame } unless @source.respond_to?(:next_frame)

        until @document.cancelled?
          yield @source.next_frame(timeout: 0.05)
          break if @source.eof?
        end
      end
    end
  end
end
