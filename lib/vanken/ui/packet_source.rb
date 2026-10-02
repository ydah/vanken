# frozen_string_literal: true

module Vanken
  module UI
    class PacketSource
      def initialize(ui)
        @ui = ui
        reset
      end
      def reset = (@rows = {}; @pending = Set.new; @last_number = nil)
      def count = @ui.document&.displayed_count || 0
      def row_id(index)
        @ui.document.number_at(index)
      rescue IndexError
        [:pending, index]
      end
      def index_of(id) = @ui.document.display_numbers.index(id)
      def cell(index, key)
        text = value(index, key)
        return nil if text.nil?
        theme = @ui.app.global(:theme)
        Zaniah::Text.new(text.to_s, font: @ui.monospace_font, size: theme.typography.size_sm, color: theme.colors.text)
      end
      def value(index, key)
        document = @ui.document
        number = document.number_at(index)
        if @last_number != number
          @last_number = number
          @metadata = document.store.metadata(number)
          @columns = document.columns[number]
        end
        case key
        when :no then number.to_s
        when :time
          format = @ui.preferences.get("packet_list.time_format")
          return Time.at(@metadata[:timestamp_ns] / 1_000_000_000, @metadata[:timestamp_ns] % 1_000_000_000, :nsec).strftime("%H:%M:%S.%N") if format == "absolute"
          precision = {"milli" => 3, "micro" => 6, "nano" => 9}.fetch(@ui.preferences.get("packet_list.time_precision"))
          value = if format == "delta_displayed"
            index.zero? ? 0.0 : (@metadata[:timestamp_ns] - document.store.metadata(document.number_at(index - 1))[:timestamp_ns]) / 1e9
          else
            document.time_value(number, format.to_sym)
          end
          Kernel.format("%.*f", precision, value)
        when :length then @metadata[:original_length].to_s
        when :info
          return @rows[number] if @rows.key?(number)
          return nil if @pending.include?(number)
          @pending.add(number)
          @ui.app.executor.background do
            info = document.row(number)[:info]
            @ui.app.executor.post do
              @pending.delete(number)
              next unless @ui.document.equal?(document)
              @rows[number] = info
              @rows.shift while @rows.size > @ui.preferences.get("packet_list.row_cache_rows")
              @ui.window.request_frame
            end
          rescue StandardError
            @ui.app.executor.post { @pending.delete(number) }
          end
          nil
        else @columns.fetch(key, "")
        end
      rescue IndexError
        ""
      end
    end
  end
end
