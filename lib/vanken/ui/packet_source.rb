# frozen_string_literal: true

module Vanken
  module UI
    class PacketSource
      def initialize(ui)
        @ui = ui
        reset
      end
      def reset
        @document = @ui.document
        @generation = (@generation || 0) + 1
        @rows, @pending, @requests = {}, {}, {}
        @batch_scheduled = false
        @time_format = @ui.preferences.get("packet_list.time_format")
        @precision = {"milli" => 3, "micro" => 6, "nano" => 9}.fetch(@ui.preferences.get("packet_list.time_precision"))
        @limit = @ui.preferences.get("packet_list.row_cache_rows")
        refresh
      end

      # Called by posted document notifications, never once per rendered cell.
      def refresh
        return reset unless @document.equal?(@ui.document)
        @count = @document&.displayed_count || 0
        @packet_count = @document&.count || 0
        @numbers = {}
        if @time_format == "delta_displayed"
          @generation += 1
          @rows, @pending, @requests = {}, {}, {}
          @batch_scheduled = false
        end
        self
      end

      def count = @count
      def packet_count = @packet_count
      def row_id(index)
        return [:pending, index] unless index.is_a?(Integer) && index.between?(0, @count - 1)
        @numbers[index] ||= @document.number_at(index)
      rescue IndexError
        [:pending, index]
      end
      def index_of(id) = @numbers.key(id) || @document&.display_numbers&.index(id)
      def cell(index, key)
        text = value(index, key)
        return nil if text.nil?
        theme = @ui.app.global(:theme)
        Zaniah::Text.new(text.to_s, font: @ui.monospace_font, size: theme.typography.size_sm, color: theme.colors.text)
      end
      def value(index, key)
        number = row_id(index)
        return "" unless number.is_a?(Integer)
        return number.to_s if key == :no
        request_row(number, index) unless @rows.key?(number) || @pending.key?(number)
        @rows[number]&.fetch(key, "")
      end

      private

      def request_row(number, index)
        @pending[number] = @generation
        @requests[number] = index
        return if @batch_scheduled
        @batch_scheduled = true
        generation = @generation
        @ui.app.executor.post { flush_rows if generation == @generation && @document.equal?(@ui.document) }
      end

      def flush_rows
        document, generation, format, precision = @document, @generation, @time_format, @precision
        requests, @requests = @requests, {}
        @batch_scheduled = false
        @ui.app.executor.background do
          rows = requests.to_h do |number, index|
            [number, row_values(document, number, index, format, precision)]
          end
          @ui.app.executor.post do
            next unless generation == @generation && @ui.document.equal?(document)
            rows.each do |number, values|
              @pending.delete(number)
              @rows[number] = values if values
            end
            @rows.shift while @rows.size > @limit
            @ui.window.request_frame if rows.any? { |_, values| values }
          end
        end
      end

      def row_values(document, number, index, format, precision)
        row = document.row(number)
        values = row.slice(:source, :destination, :protocol, :length, :info).transform_values(&:to_s)
        values[:time] = format_time(document, row, number, index, format, precision)
        values
      rescue StandardError
        nil
      end

      def format_time(document, row, number, index, format, precision)
        timestamp = row.fetch(:timestamp_ns)
        return Time.at(timestamp / 1_000_000_000, timestamp % 1_000_000_000, :nsec).strftime("%H:%M:%S.%#{precision}N") if format == "absolute"
        value = if format == "delta_displayed"
          previous = index.positive? && document.number_at(index - 1)
          previous ? (timestamp - document.store.metadata(previous)[:timestamp_ns]) / 1e9 : 0.0
        else
          document.time_value(number, format.to_sym)
        end
        Kernel.format("%.*f", precision, value)
      end
    end
  end
end
