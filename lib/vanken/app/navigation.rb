# frozen_string_literal: true

require_relative "search_job"

module Vanken
  module App
    module Navigation
      def displayed_index(number)
        @mutex.synchronize { @display ? @display.index(number) : (number.is_a?(Integer) && number.between?(1, @count) ? number - 1 : nil) }
      end

      def toggle_mark(number) = toggle_packet_state(@marked, number, "frame.marked")
      def toggle_ignore(number) = toggle_packet_state(@ignored, number, "frame.ignored")
      def toggle_time_reference(number) = toggle_packet_state(@time_references, number, "frame.time_relative")
      def mark_all_displayed
        @mutex.synchronize { @marked.merge(@display || (1..@count)) }
        packet_states_changed("frame.marked")
        self
      end
      def unmark_all
        @mutex.synchronize { @marked.clear }
        packet_states_changed("frame.marked")
        self
      end

      def conversation_neighbor(number, direction)
        return nil unless number.is_a?(Integer) && [1, -1].include?(direction)
        @mutex.synchronize do
          return nil unless number.between?(1, @count)
          stream = @annotations[number][:tcp_stream]
          return nil if stream.negative?
          numbers = @annotations.streams.fetch(stream, [])
          index = numbers.bsearch_index { |item| item >= number } || numbers.size
          index += direction
          while index.between?(0, numbers.size - 1)
            candidate = numbers[index]
            return candidate unless @display && !@display.include?(candidate)
            index += direction
          end
          nil
        end
      end

      def search(query, **options, &finished)
        cancel_search
        job = SearchJob.new(self, query, **options)
        @search_job = job
        snapshot = @mutex.synchronize { filter_snapshot(displayed_delta: !!job.program&.fields&.include?("frame.time_delta_displayed")) }
        @jobs << thread do
          hit = job.run(snapshot: snapshot)
          finished&.call(hit, nil) unless job.cancelled?
        rescue StandardError => error
          finished&.call(nil, error) unless job.cancelled?
        end
        job
      end
      def cancel_search
        @search_job&.cancel
        @search_job = nil
        self
      end

      private
      def toggle_packet_state(values, number, field)
        @mutex.synchronize do
          raise Vanken::Error, "invalid packet number" unless number.is_a?(Integer) && number.between?(1, @count)
          values.include?(number) ? values.delete(number) : values.add(number)
        end
        packet_states_changed(field)
        self
      end
      def packet_states_changed(field)
        @filter && @filter.fields.include?(field) ? apply_filter(@filter.expression) : notify(force: true)
      end
    end
  end
end
