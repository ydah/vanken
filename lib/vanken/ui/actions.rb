# frozen_string_literal: true

module Vanken
  module UI
    module Actions
      def self.install(ui)
        commands = {
          open: [ui.t("開く"), "cmd-o", -> { ui.open_dialog }], save: [ui.t("名前を付けて保存"), "cmd-shift-s", -> { ui.save_dialog }],
          close_file: [ui.t("ファイルを閉じる"), "cmd-w", -> { ui.close_document }], reload: [ui.t("再読み込み"), "cmd-r", -> { ui.reload_file }],
          quit: [ui.t("終了"), "cmd-q", -> { ui.quit }], preferences: [ui.t("設定"), "cmd-,", -> { ui.preferences_dialog }],
          capture: [ui.t("キャプチャ開始／停止"), "cmd-e", -> { ui.capture_toggle }], restart: [ui.t("キャプチャ再開"), nil, -> { ui.restart_capture }],
          apply_filter: [ui.t("フィルタを適用"), "enter", -> { ui.apply_filter }], clear_filter: [ui.t("フィルタをクリア"), nil, -> { ui.clear_filter }],
          filter_history: [ui.t("フィルタ履歴"), nil, -> { ui.filter_history }], bookmark: [ui.t("フィルタを保存"), nil, -> { ui.bookmark_filter }],
          filter_selected: [ui.t("選択した項目でフィルタ"), nil, -> { ui.filter_from_selection }],
          prepare_selected: [ui.t("選択した項目のフィルタを準備"), nil, -> { ui.filter_from_selection(prepare: true) }],
          columns: [ui.t("表示する列"), nil, -> { ui.columns_dialog }], autoscroll: [ui.t("末尾追従"), nil, -> { ui.toggle_autoscroll }],
          zoom_in: [ui.t("拡大"), "cmd-+", -> { ui.zoom(1) }], zoom_out: [ui.t("縮小"), "cmd--", -> { ui.zoom(-1) }], zoom_reset: [ui.t("標準サイズ"), "cmd-0", -> { ui.zoom }],
          previous_packet: [ui.t("前のパケット"), "alt-up", -> { ui.navigate(-1) }], next_packet: [ui.t("次のパケット"), "alt-down", -> { ui.navigate(1) }],
          first_packet: [ui.t("最初のパケット"), nil, -> { ui.first_packet }], last_packet: [ui.t("最後のパケット"), nil, -> { ui.last_packet }],
          go_to_packet: [ui.t("パケットへ移動"), "cmd-g", -> { ui.go_to_packet }], copy_filter: [ui.t("項目をフィルタとしてコピー"), nil, -> { ui.copy_text(ui.selected_node.filter) if ui.selected_node&.filter }]
        }
        commands.merge!(
          find_packet: [ui.t("パケット検索"), "cmd-f", -> { ui.find_packet }], find_next: [ui.t("次を検索"), "cmd-n", -> { ui.find_next }], find_prev: [ui.t("前を検索"), "cmd-b", -> { ui.find_prev }],
          mark_packet: [ui.t("マーク／解除"), "cmd-m", -> { ui.mark_packet }], mark_all_displayed: [ui.t("表示中をすべてマーク"), "cmd-shift-m", -> { ui.mark_all_displayed }], unmark_all: [ui.t("すべてのマークを解除"), "cmd-alt-m", -> { ui.unmark_all }],
          ignore_packet: [ui.t("無視／解除"), "cmd-d", -> { ui.ignore_packet }], time_reference: [ui.t("時刻基準／解除"), "cmd-t", -> { ui.time_reference }],
          prev_in_conversation: [ui.t("同一会話の前"), "cmd-,", -> { ui.prev_in_conversation }], next_in_conversation: [ui.t("同一会話の次"), "cmd-.", -> { ui.next_in_conversation }],
          coloring_rules: [ui.t("色付けルール"), nil, -> { ui.coloring_dialog }], toggle_coloring: [ui.t("色付け"), nil, -> { ui.toggle_coloring }],
          follow_tcp_stream: [ui.t("TCP ストリームを追跡"), "cmd-alt-shift-t", -> { ui.follow_tcp_stream }], decode_as: [ui.t("別プロトコルとして解析"), "cmd-shift-u", -> { ui.decode_as }],
          expert_info: [ui.t("エキスパート情報"), nil, -> { ui.expert_info }], reload_plugins: [ui.t("プラグイン再読み込み"), "cmd-shift-l", -> { ui.reload_plugins }], plugins: [ui.t("ディセクタプラグイン"), nil, -> { ui.plugins_dialog }],
          file_properties: [ui.t("キャプチャファイルのプロパティ"), "cmd-alt-shift-c", -> { ui.file_properties }], protocol_hierarchy: [ui.t("プロトコル階層"), nil, -> { ui.protocol_hierarchy }],
          conversations: [ui.t("会話"), nil, -> { ui.conversations }], endpoints: [ui.t("端点"), nil, -> { ui.endpoints }], io_graph: [ui.t("I/O グラフ"), nil, -> { ui.io_graph }],
          export_packets: [ui.t("指定パケットのエクスポート"), nil, -> { ui.export_packets }], export_dissections: [ui.t("解析結果のエクスポート"), nil, -> { ui.export_dissections }],
          command_palette: [ui.t("コマンドパレット"), "cmd-shift-k", -> { ui.command_palette }], profiles: [ui.t("プロファイル"), nil, -> { ui.profiles_dialog }])
        commands[:preferences][1] = "cmd-shift-p"
        commands[:restart][1] = "cmd-shift-r"
        {"relative" => "相対時刻", "absolute" => "絶対時刻", "delta" => "前パケットとの差", "delta_displayed" => "前表示パケットとの差", "epoch" => "エポック時刻"}.each { |name, label| commands[:"time_format_#{name}"] = [ui.t("時刻: %{name}", name: ui.t(label)), nil, -> { ui.time_format(name) }] }
        {"system" => "システム設定", "dark" => "ダーク", "light" => "ライト", "high_contrast" => "ハイコントラスト"}.each { |name, label| commands[:"theme_#{name}"] = [ui.t("テーマ: %{name}", name: ui.t(label)), nil, -> { ui.change_theme(name) }] }
        %i[selected not and and_not or or_not].zip([ui.t("選択項目"), ui.t("選択項目を除外"), "AND", "AND NOT", "OR", "OR NOT"]).each do |mode, label|
          commands[:"filter_#{mode}"] = [ui.t("適用: %{label}", label: label), nil, -> { ui.filter_from_selection(mode) }]
          commands[:"prepare_#{mode}"] = [ui.t("準備: %{label}", label: label), nil, -> { ui.filter_from_selection(mode, prepare: true) }]
        end
        {hex: ui.t("16 進数"), text: ui.t("テキスト"), dump: ui.t("ダンプ"), escaped: ui.t("エスケープした文字列")}.each do |format, label|
          commands[:"copy_#{format}"] = [ui.t("バイトをコピー: %{label}", label: label), nil, -> { ui.copy_bytes(format) }]
        end
        commands.each do |name, (title, keys, operation)|
          needs_document = %i[find_packet find_next find_prev mark_packet mark_all_displayed unmark_all ignore_packet time_reference prev_in_conversation next_in_conversation follow_tcp_stream expert_info file_properties protocol_hierarchy conversations endpoints io_graph export_packets export_dissections]
          enabled = ->(*) { !needs_document.include?(name) || !!ui.document }
          checked = name == :autoscroll ? ->(*) { ui.autoscroll? } : name == :toggle_coloring ? ->(*) { ui.coloring_enabled? } : nil
          ui.app.actions.register(name, title: title, enabled: enabled, checked: checked) { |_| operation.call }
          next unless keys
          key = ui.native? && RUBY_PLATFORM.include?("darwin") ? keys : keys.sub("cmd", "ctrl")
          ui.window.dispatcher.keymap.bind(key, name, context: name == :apply_filter ? "in_display_filter && !in_completion" : "")
        end
        ui.app.menu_bar = Zaniah::Menu.build do
          submenu(ui.t("ファイル")) { %i[open save close_file reload export_packets export_dissections quit].each { |action| item(action) } }
          submenu(ui.t("編集")) { %i[find_packet find_next find_prev mark_packet mark_all_displayed unmark_all ignore_packet time_reference copy_filter copy_hex copy_text copy_dump copy_escaped preferences profiles].each { |action| item(action) } }
          submenu(ui.t("表示")) do
            %i[columns autoscroll coloring_rules toggle_coloring zoom_in zoom_out zoom_reset].each { |action| item(action) }
            submenu(ui.t("時刻形式")) { %w[relative absolute delta delta_displayed epoch].each { |name| item(:"time_format_#{name}") } }
            submenu(ui.t("テーマ")) { %w[system dark light high_contrast].each { |name| item(:"theme_#{name}") } }
          end
          submenu(ui.t("移動")) { %i[previous_packet next_packet first_packet last_packet go_to_packet prev_in_conversation next_in_conversation].each { |action| item(action) } }
          submenu(ui.t("キャプチャ")) { %i[capture restart].each { |action| item(action) } }
          submenu(ui.t("フィルタ")) do
            %i[apply_filter clear_filter filter_history bookmark].each { |action| item(action) }
            submenu(ui.t("選択項目を適用")) { %i[selected not and and_not or or_not].each { |mode| item(:"filter_#{mode}") } }
            submenu(ui.t("選択項目から準備")) { %i[selected not and and_not or or_not].each { |mode| item(:"prepare_#{mode}") } }
          end
          submenu(ui.t("分析")) { %i[follow_tcp_stream decode_as expert_info plugins reload_plugins].each { |action| item(action) } }
          submenu(ui.t("統計")) { %i[file_properties protocol_hierarchy conversations endpoints io_graph].each { |action| item(action) } }
          submenu(ui.t("ヘルプ")) { item(:command_palette) }
        end
      end
    end
  end
end
