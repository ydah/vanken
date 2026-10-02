# frozen_string_literal: true

module Vanken
  module UI
    class MainView < Zaniah::UI::Component
      COLUMNS = [[:no, "No.", 64], [:time, "Time", 128], [:source, "Source", 164],
        [:destination, "Destination", 164], [:protocol, "Protocol", 90], [:length, "Length", 76], [:info, "Info", 560]].freeze

      def initialize(ui)
        super()
        @ui = ui
        columns = COLUMNS.map { |key, label, width| {key: key, label: label, width: width, align: %i[no time length].include?(key) ? :end : :start} }
        saved = ui.preferences.get("layout.columns")
        unless saved.empty?
          columns = columns.sort_by { |column| saved.index { |item| item["key"] == column[:key].to_s } || columns.size }.map do |column|
            value = saved.find { |item| item["key"] == column[:key].to_s }
            value ? column.merge(width: value["width"], visible: value["visible"]) : column
          end
        end
        table = Zaniah::UI::VirtualTable.new(ui.packet_source, columns: columns, follow_tail: ui.autoscroll?)
          .test_id("vk.packet_list").on_select { |index, *_| number = ui.packet_source.row_id(index); ui.select_packet(number) if number.is_a?(Integer) }
          .on_sort { |key, direction, _| ui.document&.sort(key, direction) }
          .on_columns_change { |items, _| ui.preferences.set("layout.columns", items.map { |item| {"key" => item[:key].to_s, "width" => item[:width], "visible" => item[:visible]} }) }
        tree = Zaniah::UI::TreeView.new([]).test_id("vk.packet_details").on_select { |node, *_| ui.select_detail(node) }
          .on_context_menu { |node, _| ui.selection_menu(node.filter) }
        table.on_row_context_menu do |index, _|
          number = ui.packet_source.row_id(index)
          table.select(index) if number.is_a?(Integer)
          ui.selection_menu(number.is_a?(Integer) ? "frame.number == #{number}" : nil)
        end
        hex = Zaniah::UI::HexView.new("".b).test_id("vk.packet_bytes").on_select { |range, _| ui.select_bytes(range) }
          .on_copy { |range, _| ui.copy_text(ui.selected_bytes.byteslice(range).unpack1("H*").scan(/../).join(" ")) }
        ui.install_panes(table, tree, hex)
        ratios = ui.preferences.get("layout.ratios")
        @lower = Zaniah::UI::SplitPane.new(pane("Packet details", tree), pane("Packet bytes", hex), ratio: ratios[1])
          .on_change { |ratio, _| ratios[1] = ratio; ui.preferences.set("layout.ratios", ratios.dup) }
        @split = Zaniah::UI::SplitPane.new(table, @lower, orientation: :vertical, ratio: ratios[0])
          .on_change { |ratio, _| ratios[0] = ratio; ui.preferences.set("layout.ratios", ratios.dup) }
      end

      def build(cx)
        ui = @ui
        doc = ui.document
        doc.frame_latency = cx.window.frame_stats.fetch(:frame_ms, 0) / 1000 if doc
        height = [cx.window.content_size.height - 132, 120].max
        table_height = [height * @split.ratio, 48].max
        lower_height = [(height * (1 - @split.ratio)) - 32, 32].max
        heights = [table_height, lower_height]
        if heights != @heights
          ui.table.viewport_height = table_height
          ui.tree.viewport_height = lower_height
          ui.hex.viewport_height = lower_height
          @heights = heights
        end
        root = Zaniah::Div.new.w_full.h_full.flex_col.bg(cx.theme.colors.background)
        root.child(Zaniah::UI::MenuBar.from(ui.app.menu_bar)) unless RUBY_PLATFORM.include?("darwin") && ui.native?
        toolbar_items = [
          button("開く", "vk.open") { ui.open_dialog },
          button("保存", "vk.save", disabled: !doc) { ui.save_dialog },
          button(ui.capture.running? ? "停止" : "開始", "vk.capture") { ui.capture_toggle },
          button("再開", "vk.restart", disabled: !ui.capture.options) { ui.restart_capture },
          button(ui.autoscroll? ? "末尾追従 ✓" : "末尾追従", "vk.autoscroll") { ui.toggle_autoscroll }]
        if doc&.loading? && doc.source == :file
          toolbar_items << button("読み込みを中止", "vk.file.cancel") { doc.cancel }
        end
        root.child(Zaniah::UI::Toolbar.new(*toolbar_items))
        root.child(Zaniah::Div.new.flex_row.items_center.gap(6).p([4, 8])
          .child(Zaniah::Div.new.flex_1.focusable(context: {in_display_filter: true}).child(ui.filter_field)).child(button("適用", "vk.filter.apply", disabled: !doc) { ui.apply_filter })
          .child(button("クリア", "vk.filter.clear") { ui.clear_filter })
          .child(button("履歴", "vk.filter.history") { ui.filter_history }))
        root.child(doc ? @split.flex_1 : welcome(cx).flex_1)
        root.child(Zaniah::UI::StatusBar.new(Zaniah::UI::Label.new(ui.status_text, size: :xs)).test_id("vk.status"))
        root.child(ui.dialog) if ui.dialog
        root.on_drop(types: ["text/uri-list"]) do |event, _|
          event.content.formats.fetch("text/uri-list", "").each_line do |line|
            next if line.start_with?("#") || line.strip.empty?
            uri = URI.parse(line.strip)
            next unless uri.scheme == "file" && [nil, "", "localhost"].include?(uri.host) && !uri.query && !uri.fragment
            path = URI::DEFAULT_PARSER.unescape(uri.path).force_encoding(Encoding::UTF_8)
            next unless path.start_with?("/") && path.valid_encoding? && !path.include?("\0")
            ui.open_file(path)
            break
          end
          true
        rescue URI::InvalidURIError
          false
        end
        root
      end

      private

      def pane(title, body) = Zaniah::Div.new.w_full.h_full.flex_col.child(Zaniah::UI::Label.new(title, size: :xs, tone: :muted).p([4, 8])).child(body)
      def button(label, id, disabled: false, &block) = Zaniah::UI::Button.new(label, size: :sm, variant: :secondary).disabled(disabled).test_id(id).on_click(&block)
      def welcome(_cx)
        content = Zaniah::Div.new.flex_col.p(24).gap(12).test_id("vk.welcome")
          .child(Zaniah::UI::Label.new("Vanken", size: :xl))
          .child(Zaniah::UI::Label.new("パケットキャプチャを開くか、インタフェースを選択してキャプチャを開始します。", tone: :muted, wrap: :word))
          .child(Zaniah::UI::Button.new("キャプチャファイルを開く").on_click { @ui.open_dialog })
          .child(Zaniah::UI::Button.new("インタフェースを選択").on_click { @ui.capture_options })
        @ui.preferences.recent_files.first(10).each do |path|
          content.child(Zaniah::UI::Button.new(path, size: :sm, variant: :ghost).on_click { @ui.open_file(path) })
        end
        (@ui.interface_infos || []).each do |info|
          name = info.fetch(:name)
          content.child(Zaniah::UI::Button.new("#{name}  #{info[:description]}", size: :sm, variant: :ghost)
            .on_click { @ui.capture_options(interface: name) })
        end
        content
      end
    end
  end
end
