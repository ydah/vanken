# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Capture
    class Receiver
      def initialize(document, source) = (@document, @source = document, source)
      def run
        flushed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @source.each do |frame|
          break if @document.cancelled?
          number = @document.store.append(frame)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if number % 256 == 0 || now - flushed_at >= 0.05 || number == 50
            @document.store.flush
            @document.signal
            flushed_at = now
          end
        end
      rescue StandardError => error
        @document.fail(error)
      ensure
        @document.store.flush
        @document.receiving_done
        @source.close if @source.respond_to?(:close)
      end
    end
  end
end
