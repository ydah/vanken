# frozen_string_literal: true

require_relative "../core/display_filter/compiler"

module Vanken
  module App
    IOPoint = Data.define(:interval, :start_ns, :packets, :bytes)
    IOSeries = Data.define(:expression, :interval_ns, :points, :omitted_intervals)

    module IOGraph
      INTERVALS = [0.01, 0.1, 1, 10, 60].freeze

      def self.build(document, interval: 1, series: [""], displayed_only: false, cancelled: nil)
        raise ArgumentError, "invalid I/O interval" unless INTERVALS.include?(interval)
        raise ArgumentError, "I/O graph needs 1-64 series" unless series.size.between?(1, 64) && series.all? { |expression| expression.is_a?(String) }
        interval_ns = (interval * 1_000_000_000).to_i
        programs = series.map { |expression| Core::DisplayFilter.compile(expression, catalog: document.catalog) }
        numbers = displayed_only ? document.display_numbers : (1..document.count)
        start = document.count.zero? ? 0 : document.store.metadata(1)[:timestamp_ns]
        bins = series.map { {} }
        last = 0
        numbers.each do |number|
          raise Vanken::Error, "operation cancelled" if document.closing? || cancelled&.call
          metadata = document.store.metadata(number)
          index = [(metadata[:timestamp_ns] - start) / interval_ns, 0].max
          last = [last, index].max
          view = nil
          programs.each_with_index do |program, position|
            next unless series[position].empty? || program.match?(view ||= document.view(number))
            row = (bins[position][index] ||= [0, 0])
            row[0] += 1
            row[1] += metadata[:original_length]
          end
        end
        # ponytail: retain at most 100,000 intervals; coarsen the selected interval for longer captures.
        first = [last - 99_999, 0].max
        series.each_with_index.map do |expression, position|
          points = (document.count.zero? ? [] : (first..last)).map do |index|
            packets, bytes = bins[position].fetch(index, [0, 0])
            IOPoint.new(interval: index, start_ns: start + (index * interval_ns), packets: packets, bytes: bytes)
          end
          IOSeries.new(expression: expression, interval_ns: interval_ns, points: points.freeze, omitted_intervals: first)
        end
      end
    end
  end
end
