# frozen_string_literal: true

require_relative "../core/display_filter/compiler"

module Vanken
  module App
    class SearchJob
      attr_reader :program
      def initialize(document, query, mode: :filter, target: :bytes, from: nil, direction: 1)
        @document, @mode, @target, @from = document, mode.to_sym, target.to_sym, from
        raise Vanken::Error, "invalid search mode or target" unless %i[filter hex string regex].include?(@mode) && %i[list details bytes].include?(@target)
        raise Vanken::Error, "search query is empty" if query.empty?
        raise Vanken::Error, "invalid search direction" unless [1, -1].include?(direction)
        @direction = direction
        @program = Core::DisplayFilter.compile(query, catalog: document.catalog) if @mode == :filter
        @query = if @mode == :hex
          hex = query.delete(" \t\r\n:")
          raise Vanken::Error, "16 進数は 2 桁ずつ入力してください" unless /\A(?:[\da-fA-F]{2})+\z/.match?(hex)
          [hex].pack("H*")
        elsif @mode == :regex
          Regexp.new(@target == :bytes ? query.b : query, timeout: 0.1)
        else
          query.dup
        end
      rescue RegexpError => error
        raise Vanken::Error, "invalid search pattern: #{error.message}"
      end

      def cancel = @cancelled = true
      def cancelled? = @cancelled || @document.closing?
      def run(snapshot: nil)
        limit = @document.displayed_count
        return nil if limit.zero?
        origin = @document.displayed_index(@from) || (@direction.positive? ? -1 : limit)
        1.upto(limit) do |step|
          return nil if cancelled?
          number = @document.number_at((origin + (step * @direction)) % limit)
          matched = if @mode == :filter
            @program.match?(@document.view(number, snapshot: snapshot))
          else
            text = search_text(number)
            @mode == :regex ? @query.match?(text) : text.b.include?(@query.b)
          end
          return number if matched && !cancelled?
          Thread.pass if step % 256 == 0
        end
        nil
      rescue Regexp::TimeoutError
        raise Vanken::Error, "検索の正規表現が時間制限を超えました"
      end

      private
      def search_text(number)
        case @target
        when :bytes then @document.store.read(number).bytes
        when :list then @document.row(number).values.join("\t")
        when :details then @document.details(number).flat_map(&:descendants).map(&:label).join("\n")
        end
      end
    end
  end
end
