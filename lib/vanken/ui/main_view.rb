# frozen_string_literal: true

require_relative "../config/columns"

module Vanken
  module UI
    class MainView < Zaniah::UI::Component
      COLUMNS = Config::Columns::BUILTINS

      class ExpertBadge < Zaniah::UI::Badge
        def initialize(label, variant:, &activate)
          super(label, variant: variant)
          @label, @activate = label, activate
        end
        def build(cx)
          super.cursor(:pointer).on_click { @activate.call }
            .focusable(context: {in_button: true}) { |action| action == :activate && (@activate.call; true) }
        end
        def accessibility_node(_cx) = node(:button, label: @label, actions: [:press])
        def accessibility_action(_node, action) = action == :press && (@activate.call; true)
      end

      def initialize(ui)
        super()
        @ui = ui
        @filter_container = Zaniah::Div.new.flex_1.focusable(context: {in_display_filter: true}).child(ui.filter_field)
        @menu_bar = Zaniah::UI::MenuBar.from(ui.app.menu_bar)
        settings = ui.respond_to?(:column_settings) ? ui.column_settings : Config::Columns.load(directory: ui.preferences.directory, legacy: ui.preferences.get("layout.columns"))
        columns = settings.table_columns.map do |column|
          default = COLUMNS.find { |key, *_| key == column[:key] }
          default && column[:label] == default[1] ? column.merge(label: text(column[:label])) : column
        end
        ui.document.custom_columns = settings.custom if ui.document
        table = Zaniah::UI::VirtualTable.new(ui.packet_source, columns: columns, follow_tail: ui.autoscroll?, label: text("パケット一覧"))
          .test_id("vk.packet_list").on_select { |index, *_| number = ui.packet_source.row_id(index); ui.select_packet(number) if number.is_a?(Integer) }
          .on_sort { |key, direction, _| ui.document&.sort(key, direction) }
          .on_columns_change do |items, _|
            if ui.respond_to?(:persist_columns_layout)
              ui.persist_columns_layout(items)
            else
              settings.update_layout(items)
              settings.save(ui.preferences.directory)
            end
          end
        tree = Zaniah::UI::TreeView.new([], label: text("パケット詳細")).test_id("vk.packet_details").on_select { |node, *_| ui.select_detail(node) }
          .on_context_menu { |node, _| ui.respond_to?(:field_menu) ? ui.field_menu(node) : ui.selection_menu(node.filter) }
        table.on_row_context_menu do |index, _|
          number = ui.packet_source.row_id(index)
          table.select(index) if number.is_a?(Integer)
          ui.selection_menu(number.is_a?(Integer) ? "frame.number == #{number}" : nil, number: number.is_a?(Integer) ? number : nil)
        end
        hex = Zaniah::UI::HexView.new("".b).accessibility_label(text("パケットバイト")).test_id("vk.packet_bytes").on_select { |range, _| ui.select_bytes(range) }
          .on_copy { |range, _| ui.copy_text(ui.selected_bytes.byteslice(range).unpack1("H*").scan(/../).join(" ")) }
        ui.install_panes(table, tree, hex)
        ratios = ui.preferences.get("layout.ratios")
        @lower = Zaniah::UI::SplitPane.new(pane("Packet details", tree), pane("Packet bytes", hex), ratio: ratios[1])
          .on_change { |ratio, _| ratios[1] = ratio; ui.preferences.set("layout.ratios", ratios.dup) }
        @split = Zaniah::UI::SplitPane.new(table, @lower, orientation: :vertical, ratio: ratios[0])
          .on_change { |ratio, _| ratios[0] = ratio; ui.preferences.set("layout.ratios", ratios.dup) }
      end

      def build(cx)
        @previous_buttons, @buttons = @buttons || {}, {}
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
        root.child(@menu_bar) unless RUBY_PLATFORM.include?("darwin") && ui.native?
        toolbar_items = [
          button("開く", "vk.open") { ui.open_dialog },
          button("保存", "vk.save", disabled: !doc) { ui.save_dialog },
          button(ui.capture.running? ? "停止" : "開始", "vk.capture") { ui.capture_toggle },
          button("再開", "vk.restart", disabled: !ui.capture.options) { ui.restart_capture },
          button(ui.autoscroll? ? "末尾追従 ✓" : "末尾追従", "vk.autoscroll") { ui.toggle_autoscroll }]
        if doc&.loading? && doc.source == :file
          toolbar_items << button("読み込みを中止", "vk.file.cancel") { doc.cancel }
        end
        root.child(Zaniah::UI::Toolbar.new(*toolbar_items).accessibility_label(text("キャプチャ操作")))
        root.child(Zaniah::Div.new.flex_row.items_center.gap(6).p([4, 8])
          .child(@filter_container).child(button("適用", "vk.filter.apply", disabled: !doc) { ui.apply_filter })
          .child(button("クリア", "vk.filter.clear") { ui.clear_filter })
          .child(button("履歴", "vk.filter.history") { ui.filter_history }))
        root.child(doc ? @split.flex_1 : welcome(cx).flex_1)
        status = [Zaniah::UI::Label.new(ui.status_text, size: :xs).flex_1]
        summary = doc.respond_to?(:expert_summary) ? doc.expert_summary : nil
        if summary && summary[:count].positive?
          severity = %w[note note warning error].fetch(summary[:severity])
          caption = {"note" => "注記", "warning" => "警告", "error" => "エラー"}.fetch(severity)
          badge = ExpertBadge.new("#{text(caption)}: #{summary[:count]}", variant: {"note" => :neutral, "warning" => :warning, "error" => :danger}.fetch(severity)) { ui.expert_info }
            .test_id("vk.expert.badge")
          status << badge
        end
        root.child(Zaniah::UI::StatusBar.new(*status).test_id("vk.status"))
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

      def text(value) = @ui.respond_to?(:t) ? @ui.t(value) : value
      def pane(title, body) = Zaniah::Div.new.w_full.h_full.flex_col.child(Zaniah::UI::Label.new(text(title), size: :xs, tone: :muted).p([4, 8])).child(body)
      def button(label, id, disabled: false, size: :sm, variant: :secondary, &block)
        caption = text(label)
        key = [id, caption, size, variant]
        @buttons[key] = (@previous_buttons[key] || Zaniah::UI::Button.new(caption, size: size, variant: variant).test_id(id)).disabled(disabled).on_click(&block)
      end
      def welcome(cx)
        content = Zaniah::Div.new.flex_col.p(24).gap(12).test_id("vk.welcome")
          .child(Zaniah::UI::Label.new("Vanken", size: :xl))
          .child(Zaniah::UI::Label.new(text("パケットキャプチャを開くか、インタフェースを選択してキャプチャを開始します。"), tone: :muted, wrap: :word))
          .child(button("キャプチャファイルを開く", "vk.welcome.open", size: :md, variant: :primary) { @ui.open_dialog })
          .child(button("インタフェースを選択", "vk.welcome.capture", size: :md, variant: :primary) { @ui.capture_options })
        @ui.preferences.recent_files.first(10).each do |path|
          content.child(button(path, "vk.recent.#{path}", variant: :ghost) { @ui.open_file(path) })
        end
        (@ui.interface_infos || []).each do |info|
          name = info.fetch(:name)
          traffic = @ui.respond_to?(:interface_traffic) ? (@ui.interface_traffic || {}) : {}
          values = (traffic[:history] || {}).fetch(name, [])
          values = [0] if values.empty?
          rate = (traffic[:rates] || {}).fetch(name, 0)
          row = Zaniah::Div.new.flex_row.items_center.gap(8)
            .child(button("#{name}  #{info[:description]}", "vk.interface.#{name}", variant: :ghost) { @ui.capture_options(interface: name) }.flex_1)
            .child(Zaniah::UI::Sparkline.new(values, width: 100, height: 24, label: "#{name} #{text('トラフィック')}").test_id("vk.interface.traffic.#{name}"))
            .child(Zaniah::UI::Label.new("#{rate} B/s", size: :xs, tone: :muted))
          content.child(row)
        end
        @welcome_scroll ||= Zaniah::ScrollView.new
        @welcome_scroll.children.clear
        @welcome_scroll.h([cx.window.content_size.height - 132, 120].max).child(content)
      end
    end
  end
end
