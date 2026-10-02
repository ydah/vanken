# frozen_string_literal: true

require_relative "../gateway/statistics"

module Vanken
  module App
    # Invoke refresh on the executor; cancel joins its current frame before store close.
    class StatsJob
      def initialize(document, specs: ["phs"], displayed_only: false)
        @document, @specs, @displayed_only = document, specs, displayed_only
        @mutex, @numbers, @cancelled = Mutex.new, [], false
        reset
      end

      def refresh
        @mutex.synchronize do
          return [] if @cancelled || @document.closing?
          numbers = @displayed_only ? @document.display_numbers.sort : (1..@document.count).to_a
          reset unless numbers.take(@numbers.size) == @numbers
          numbers.drop(@numbers.size).each do |number|
            break if @cancelled || @document.closing?
            @statistics.update(@dissector.dissect(@document.store.read(number)))
            @numbers << number
          end
          @statistics.tables
        end
      end

      def cancel
        @cancelled = true
        @mutex.synchronize { @statistics.close }
        self
      end

      private

      def reset
        @statistics&.close
        @numbers = []
        @dissector = Gateway::Dissector.new(**@document.analysis_gateway_options)
        @statistics = Gateway::Statistics.new(specs: @specs, registry: @dissector.registry, **@document.analysis_options)
      end
    end
  end
end
