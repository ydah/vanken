# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Capture
    class Analyzer
      def initialize(document, dissector)
        @document, @dissector = document, dissector
        @analysis = Gateway::Analysis.new(registry: dissector.registry, **document.analysis_options)
      end
      def run
        number = 1
        loop do
          break if @document.respond_to?(:closing?) && @document.closing?
          if number > @document.store.durable_count
            break if @document.received? && number > @document.store.durable_count
            @document.wait_for_frames
            next
          end
          frame = @document.store.read(number)
          begin
            packet = @dissector.dissect(frame)
            @analysis.update(packet)
          rescue StandardError => error
            @document.publish_failure(number, error)
            packet = nil
          end
          @document.publish(number, packet) if packet
          number += 1
          if number % 256 == 0
            Thread.pass
            sleep(0.002) if @document.frame_latency > 0.033
          end
        end
      ensure
        begin
          @analysis.close
        ensure
          @document.analyzing_done
        end
      end
    end
  end
end
