# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Capture
    class Analyzer
      def initialize(document, dissector)
        @document, @dissector = document, dissector
        @analysis = Gateway::Analysis.new(registry: dissector.registry)
      end
      def run
        number = 1
        loop do
          break if @document.cancelled?
          if number > @document.store.durable_count
            break if @document.received?
            @document.wait_for_frames
            next
          end
          frame = @document.store.read(number)
          begin
            packet = @dissector.dissect(frame)
            @analysis.update(packet)
            @document.publish(number, packet)
          rescue StandardError => error
            @document.publish_failure(number, error)
          end
          number += 1
          if number % 256 == 0
            Thread.pass
            sleep(0.002) if @document.frame_latency > 0.033
          end
        end
      ensure
        @analysis.close
        @document.analyzing_done
      end
    end
  end
end
