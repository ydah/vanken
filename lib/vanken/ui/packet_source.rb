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
        @refresh_pending = @refresh_again = nil
        @time_format = @ui.preferences.get("packet_list.time_format")
        @precision = {"milli" => 3, "micro" => 6, "nano" => 9}.fetch(@ui.preferences.get("packet_list.time_precision"))
        @limit = @ui.preferences.get("packet_list.row_cache_rows")
        refresh
      end

      # Called by posted document notifications, never once per rendered cell.
      def refresh(&ready)
        return reset.tap { ready&.call } unless @document.equal?(@ui.document)
        count, packet_count = @document&.displayed_count || 0, @document&.count || 0
        range = ready && @count && count > @count && @ui.autoscroll? && @ui.table&.body&.visible_range
        if range && range.size.positive?
          if @refresh_pending
            @refresh_again = ready
          else
            refresh_tail(count, packet_count, range.size + 2, ready)
          end
        else
          @refresh_pending = @refresh_again = nil
          publish_counts(count, packet_count)
          ready&.call
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

      def publish_counts(count, packet_count)
        @count, @packet_count, @numbers = count, packet_count, {}
        if @time_format == "delta_displayed"
          @generation += 1
          @rows, @pending, @requests = {}, {}, {}
          @batch_scheduled = false
        end
      end

      def refresh_tail(count, packet_count, size, ready)
        document, generation, format, precision = @document, @generation, @time_format, @precision
        first = [count - size, 0].max
        numbers = (first...count).to_h { |index| [index, document.number_at(index)] }
        previous = format == "delta_displayed" && first.positive? && document.number_at(first - 1)
        @refresh_pending = numbers
        @ui.app.executor.background do
          rows = numbers.to_h do |index, number|
            values = row_values(document, number, index, format, precision, previous)
            previous = number
            [number, values]
          end
          @ui.app.executor.post do
            next unless @refresh_pending.equal?(numbers) && generation == @generation && @ui.document.equal?(document)
            again, @refresh_again, @refresh_pending = @refresh_again, nil, nil
            publish_counts(count, packet_count)
            @numbers = numbers
            rows.each do |number, values|
              @pending.delete(number)
              @rows[number] = values if values
            end
            @rows.shift while @rows.size > @limit
            if again && document.displayed_count == count && document.count == packet_count
              ready, again = again, nil
            end
            published_generation = @generation
            ready.call
            refresh(&again) if again && published_generation == @generation && @ui.document.equal?(document)
          end
        end
      rescue IndexError
        refresh
        ready.call
      end

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

      def row_values(document, number, index, format, precision, previous = :current)
        row = document.row(number)
        values = row.slice(:source, :destination, :protocol, :length, :info).transform_values(&:to_s)
        values[:time] = format_time(document, row, number, index, format, precision, previous)
        values
      rescue StandardError
        nil
      end

      def format_time(document, row, number, index, format, precision, previous = :current)
        timestamp = row.fetch(:timestamp_ns)
        return Time.at(timestamp / 1_000_000_000, timestamp % 1_000_000_000, :nsec).strftime("%H:%M:%S.%#{precision}N") if format == "absolute"
        value = if format == "delta_displayed"
          previous = index.positive? && document.number_at(index - 1) if previous == :current
          previous ? (timestamp - document.store.metadata(previous)[:timestamp_ns]) / 1e9 : 0.0
        else
          document.time_value(number, format.to_sym)
        end
        Kernel.format("%.*f", precision, value)
      end
    end
  end
end
