# frozen_string_literal: true

module Vanken
  module UI
    module NavigationOperations
      def mark_packet = update_packet_state(:toggle_mark)
      def ignore_packet = update_packet_state(:toggle_ignore)
      def time_reference = update_packet_state(:toggle_time_reference)
      def mark_all_displayed = update_packet_state(:mark_all_displayed, selected: false)
      def unmark_all = update_packet_state(:unmark_all, selected: false)
      def prev_in_conversation = navigate_conversation(-1)
      def next_in_conversation = navigate_conversation(1)

      def find_packet
        mode = @search_mode || :filter
        target = @search_target || :bytes
        field = Zaniah::UI::TextField.new(@search_query || "", label: t("検索内容")).test_id("vk.search.query")
        modes = Zaniah::UI::SegmentedControl.new([[t("表示フィルタ"), :filter], [t("16 進"), :hex], [t("文字列"), :string], [t("正規表現"), :regex]], value: mode, label: t("検索形式"))
          .on_change { |value, *_| mode = value }.test_id("vk.search.mode")
        targets = Zaniah::UI::Select.new([[t("パケット一覧"), :list], [t("パケット詳細"), :details], [t("パケットバイト"), :bytes]], label: t("検索対象"), value: target)
          .on_change { |value, *_| target = value }.test_id("vk.search.target")
        content = Zaniah::Div.new.flex_col.gap(12).child(modes).child(targets).child(field)
          .child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Button.new(t("次を検索")).test_id("vk.search.next").on_click { search_packets(field.value, mode: mode, target: target) })
            .child(Zaniah::UI::Button.new(t("前を検索"), variant: :secondary).on_click { search_packets(field.value, mode: mode, target: target, direction: -1) })
            .child(Zaniah::UI::Button.new(t("キャンセル"), variant: :secondary).on_click { cancel_packet_search; dismiss_dialog }))
        show_dialog(:search, t("パケット検索"), content, reopen: -> { @search_query, @search_mode, @search_target = field.value, mode, target; find_packet })
      end

      def search_result_dialog
        show_dialog(:search_result, t("パケット検索"), Zaniah::UI::Label.new(t("一致するパケットはありません。"), wrap: :word), reopen: -> { search_result_dialog })
      end

      def find_next = repeat_packet_search(1)
      def find_prev = repeat_packet_search(-1)
      def cancel_packet_search
        @search_generation = (@search_generation || 0) + 1
        document&.cancel_search
      end

      def search_packets(query, mode: :filter, target: :bytes, direction: 1)
        doc = document
        return unless doc
        cancel_packet_search
        generation = @search_generation
        @search_query, @search_mode, @search_target = query, mode, target
        doc.search(query, mode: mode, target: target, from: selected_number, direction: direction) do |number, error|
          @app.executor.post do
            next unless !@closing && generation == @search_generation && document.equal?(doc)
            if error
              show_error(error)
            elsif number
              select_found_packet(number)
            else
              search_result_dialog
            end
          end
        end
        dismiss_dialog if @dialog_kind == :search
      rescue StandardError => error
        show_error(error)
      end

      private
      def repeat_packet_search(direction)
        @search_query && !@search_query.empty? ? search_packets(@search_query, mode: @search_mode, target: @search_target, direction: direction) : find_packet
      end
      def select_found_packet(number)
        index = document&.displayed_index(number)
        return unless index
        @table.select(index)
        @table.scroll_to(index, align: :center)
      end
      def navigate_conversation(direction)
        number = document&.conversation_neighbor(selected_number, direction)
        select_found_packet(number) if number
      end
      def update_packet_state(operation, selected: true, number: selected_number)
        return unless document && (!selected || number)
        selected ? document.public_send(operation, number) : document.public_send(operation)
        @packet_source.reset
        @window.request_frame
      end
    end
  end
end
