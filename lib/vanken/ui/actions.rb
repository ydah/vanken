# frozen_string_literal: true

module Vanken
  module UI
    module Actions
      def self.install(ui)
        commands = {
          open: ["開く", "cmd-o", -> { ui.open_dialog }], save: ["名前を付けて保存", "cmd-shift-s", -> { ui.save_dialog }],
          close_file: ["ファイルを閉じる", "cmd-w", -> { ui.close_document }], reload: ["再読み込み", "cmd-r", -> { ui.reload_file }],
          quit: ["終了", "cmd-q", -> { ui.quit }], preferences: ["設定", "cmd-,", -> { ui.preferences_dialog }],
          capture: ["キャプチャ開始／停止", "cmd-e", -> { ui.capture_toggle }], restart: ["キャプチャ再開", nil, -> { ui.restart_capture }],
          apply_filter: ["フィルタを適用", "enter", -> { ui.apply_filter }], clear_filter: ["フィルタをクリア", nil, -> { ui.clear_filter }],
          filter_history: ["フィルタ履歴", nil, -> { ui.filter_history }], bookmark: ["フィルタを保存", nil, -> { ui.bookmark_filter }],
          filter_selected: ["選択した項目でフィルタ", nil, -> { ui.filter_from_selection }],
          prepare_selected: ["選択した項目のフィルタを準備", nil, -> { ui.filter_from_selection(prepare: true) }],
          columns: ["表示する列", nil, -> { ui.columns_dialog }], autoscroll: ["末尾追従", nil, -> { ui.toggle_autoscroll }],
          zoom_in: ["拡大", "cmd-+", -> { ui.zoom(1) }], zoom_out: ["縮小", "cmd--", -> { ui.zoom(-1) }], zoom_reset: ["標準サイズ", "cmd-0", -> { ui.zoom }],
          previous_packet: ["前のパケット", "alt-up", -> { ui.navigate(-1) }], next_packet: ["次のパケット", "alt-down", -> { ui.navigate(1) }],
          first_packet: ["最初のパケット", nil, -> { ui.first_packet }], last_packet: ["最後のパケット", nil, -> { ui.last_packet }],
          go_to_packet: ["パケットへ移動", "cmd-g", -> { ui.go_to_packet }], copy_filter: ["項目をフィルタとしてコピー", nil, -> { ui.copy_text(ui.selected_node.filter) if ui.selected_node&.filter }]
        }
        %i[selected not and and_not or or_not].zip(["選択項目", "選択項目を除外", "AND", "AND NOT", "OR", "OR NOT"]).each do |mode, label|
          commands[:"filter_#{mode}"] = ["適用: #{label}", nil, -> { ui.filter_from_selection(mode) }]
          commands[:"prepare_#{mode}"] = ["準備: #{label}", nil, -> { ui.filter_from_selection(mode, prepare: true) }]
        end
        {hex: "16 進数", text: "テキスト", dump: "ダンプ", escaped: "エスケープした文字列"}.each do |format, label|
          commands[:"copy_#{format}"] = ["バイトをコピー: #{label}", nil, -> { ui.copy_bytes(format) }]
        end
        commands.each do |name, (title, keys, operation)|
          ui.app.actions.register(name, title: title) { |_| operation.call }
          next unless keys
          key = RUBY_PLATFORM.include?("darwin") ? keys : keys.sub("cmd", "ctrl")
          ui.window.dispatcher.keymap.bind(key, name, context: name == :apply_filter ? "in_display_filter && !in_completion" : "")
        end
        ui.app.menu_bar = Zaniah::Menu.build do
          submenu("ファイル") { %i[open save close_file reload quit].each { |action| item(action) } }
          submenu("編集") { %i[copy_filter copy_hex copy_text copy_dump copy_escaped preferences].each { |action| item(action) } }
          submenu("表示") { %i[columns autoscroll zoom_in zoom_out zoom_reset].each { |action| item(action) } }
          submenu("移動") { %i[previous_packet next_packet first_packet last_packet go_to_packet].each { |action| item(action) } }
          submenu("キャプチャ") { %i[capture restart].each { |action| item(action) } }
          submenu("フィルタ") do
            %i[apply_filter clear_filter filter_history bookmark].each { |action| item(action) }
            submenu("選択項目を適用") { %i[selected not and and_not or or_not].each { |mode| item(:"filter_#{mode}") } }
            submenu("選択項目から準備") { %i[selected not and and_not or or_not].each { |mode| item(:"prepare_#{mode}") } }
          end
        end
      end
    end
  end
end
