# frozen_string_literal: true

module Vanken
  module UI
    module Selection
      def select_packet(number)
        doc = document
        return unless doc && number.is_a?(Integer) && number.between?(1, doc.count)
        @selection_generation += 1
        generation = @selection_generation
        expanded = @pending_tree_expansion ||= @tree.expanded.dup
        update { |state| state.merge!(number: number, node: nil, details: [], bytes: "".b) }
        @tree.replace([])
        @hex.bytes = "".b
        @app.executor.background do
          nodes = doc.details(number)
          bytes = doc.store.read(number).bytes
          @app.executor.post do
            next unless generation == @selection_generation && document.equal?(doc)
            update { |state| state.merge!(number: number, node: nil, details: nodes, bytes: bytes) }
            @tree.replace(nodes)
            expanded.each { |id| @tree.expand(id) }
            @pending_tree_expansion = nil
            @hex.bytes = bytes
          end
        rescue StandardError => error
          @app.executor.post { show_error(error) if generation == @selection_generation }
        end
      end
      def select_detail(node)
        return unless node.is_a?(Core::DetailNode)
        update { |state| state[:node] = node }
        @hex.highlights = if node.source == :frame && node.offset && node.length.positive?
          finish = [node.offset + node.length, selected_bytes.bytesize].min
          layer = detail_nodes.drop(1).find { |item| item.source == :frame && item.children.any? && item.descendants.include?(node) }
          highlights = []
          if layer&.offset && layer.length.positive?
            highlights << {range: layer.offset...[layer.offset + layer.length, selected_bytes.bytesize].min, tone: :secondary}
          end
          highlights << {range: node.offset...finish, tone: :primary} if finish > node.offset
          highlights
        else
          []
        end
        @hex.scroll_to_offset(node.offset) if node.offset && node.offset < selected_bytes.bytesize && node.source == :frame
      end
      def select_bytes(range)
        matches = detail_nodes.flat_map(&:descendants).select { |node| node.source == :frame && node.offset && node.length.positive? && range.begin.between?(node.offset, node.offset + node.length - 1) }
        node = matches.min_by { |item| [item.length, item.field ? 0 : 1] }
        return unless node
        select_detail(node)
        parent = detail_nodes.find { |item| item.descendants.include?(node) }
        @tree.expand(parent.id) if parent
        @tree.select_id(node.id)
      end
      def navigate(delta)
        return unless document && document.displayed_count.positive?
        current = document.display_numbers.index(selected_number) || 0
        index = (current + delta).clamp(0, document.displayed_count - 1)
        @table.select(index)
        @table.scroll_to(index, align: :nearest)
      end
      def first_packet
        return unless document&.displayed_count&.positive?
        @table.select(0)
        @table.scroll_to(0)
      end
      def last_packet
        return unless document&.displayed_count&.positive?
        @table.select(document.displayed_count - 1)
        @table.scroll_to(document.displayed_count - 1)
      end
      def go_to_packet
        path_dialog(t("パケットへ移動")) do |value|
          number = Integer(value, 10)
          index = document&.display_numbers&.index(number)
          raise Vanken::Error, t("指定したパケットは表示されていません") unless index
          @table.select(index)
          @table.scroll_to(index, align: :center)
          dismiss_dialog
        end
      end
      def copy_bytes(format = :hex)
        range = @hex.selection || (0...selected_bytes.bytesize)
        range = 0...selected_bytes.bytesize if range.size.zero?
        bytes = selected_bytes.byteslice(range) || "".b
        text = case format
        when :text then bytes.dup.force_encoding(Encoding::UTF_8).scrub
        when :escaped then bytes.bytes.map { |byte| byte.between?(32, 126) && ![34, 92].include?(byte) ? byte.chr : Kernel.format("\\x%02x", byte) }.join
        when :dump then bytes.bytes.each_slice(16).with_index.map { |row, index| Kernel.format("%04x  %s", range.begin + (index * 16), row.map { |byte| Kernel.format("%02x", byte) }.join(" ")) }.join("\n")
        else bytes.unpack1("H*").scan(/../).join(" ")
        end
        copy_text(text)
      end
    end
  end
end
