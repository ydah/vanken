# frozen_string_literal: true

require_relative "../config/profiles"
require_relative "../config/analysis_settings"

module Vanken
  module UI
    module SettingsOperations
      SETTING_LABELS = {
        "appearance.theme" => "テーマ", "appearance.language" => "言語", "appearance.font_size" => "文字サイズ",
        "packet_list.time_format" => "時刻表示", "packet_list.time_precision" => "時刻の精度", "packet_list.autoscroll" => "自動スクロール",
        "packet_list.row_cache_rows" => "行キャッシュ容量", "packet_list.coloring" => "色付け",
        "capture.snaplen" => "Snaplen", "capture.promiscuous" => "プロミスキャスモード", "capture.buffer_size" => "取得バッファ (bytes)",
        "capture.backend" => "キャプチャ方式", "capture.launcher" => "ヘルパー起動方式", "capture.direction" => "取得方向",
        "capture.stop_count" => "自動停止: パケット数 (0: 無効)", "capture.stop_duration" => "自動停止: 秒 (0: 無効)", "capture.stop_bytes" => "自動停止: bytes (0: 無効)",
        "capture.ring_path" => "リング保存先 (空欄: 無効)", "capture.ring_max_bytes" => "リング: ファイルごとのbytes", "capture.ring_interval" => "リング: 秒", "capture.ring_file_count" => "リング: 保持ファイル数",
        "analysis.verify_checksums" => "チェックサム検証", "analysis.max_state_mib" => "解析メモリ上限（MiB）", "analysis.max_flows" => "フロー数上限", "analysis.workers" => "ワーカー数",
        "name_resolution.enabled" => "名前解決", "name_resolution.timeout" => "解決タイムアウト（秒）", "name_resolution.cache_size" => "名前キャッシュ容量"
      }.freeze
      def analysis_settings = Config::AnalysisSettings.new(directory: @preferences.directory)

      def preferences_dialog
        groups = %w[appearance packet_list capture analysis name_resolution].map do |group|
          defaults = Config::Preferences::DEFAULTS.fetch(group)
          schema = defaults.map do |key, value|
            path = "#{group}.#{key}"
            options = {"appearance.theme" => %w[system dark light high_contrast], "appearance.language" => %w[ja en],
              "packet_list.time_format" => %w[relative absolute delta delta_displayed epoch], "packet_list.time_precision" => %w[milli micro nano],
              "capture.backend" => %w[auto ring socket bpf], "capture.launcher" => %w[auto direct sudo pkexec], "capture.direction" => %w[in out inout]}[path]
            captions = {"system" => "システム設定", "dark" => "ダーク", "light" => "ライト", "high_contrast" => "ハイコントラスト",
              "ja" => "日本語", "en" => "English", "relative" => "相対時刻", "absolute" => "絶対時刻", "delta" => "前パケットとの差", "delta_displayed" => "前表示パケットとの差", "epoch" => "エポック時刻",
              "milli" => "ミリ秒", "micro" => "マイクロ秒", "nano" => "ナノ秒", "in" => "受信", "out" => "送信", "inout" => "双方向"}
            options = options.map { |item| [t(captions.fetch(item, item)), item] } if options
            type = options ? :select : [true, false].include?(value) ? :boolean : value.is_a?(Numeric) ? :number : :text
            {key: path, label: setting_label(path), type: type, options: options || []}
          end
          values = defaults.keys.to_h { |key| [:"#{group}.#{key}", @preferences.get("#{group}.#{key}")] }
          grid = Zaniah::UI::PropertyGrid.new(schema, values, height: 240, label: setting_label(group)).test_id("vk.preferences.#{group}")
            .on_change { |key, value, *_| apply_preference(key.to_s, value) }
          [setting_label(group), grid]
        end
        content = Zaniah::Div.new.flex_col.gap(8)
          .child(Zaniah::UI::Button.new(t("プロファイルの管理")).on_click { profiles_dialog })
          .child(Zaniah::UI::Tabs.new(groups))
        show_dialog(:preferences, t("設定"), content, reopen: -> { preferences_dialog })
      end

      def apply_preference(path, value)
        old = @preferences.get(path)
        value = Integer(value) if old.is_a?(Integer)
        value = Float(value) if old.is_a?(Float)
        @preferences.set(path, value)
        if path.start_with?("appearance.")
          change_theme(@preferences.get("appearance.theme"), persist: false)
          rebuild_view if path == "appearance.language"
        elsif path.start_with?("packet_list.", "name_resolution.")
          reset_resolver if path.start_with?("name_resolution.")
          if path == "packet_list.autoscroll"
            @autoscroll = value
            @table.follow_tail = value if @table
          end
          @packet_source.reset
        elsif path.start_with?("analysis.")
          @pending_analysis_settings = true
          apply_analysis_settings
        end
        @window.request_frame
      rescue StandardError => error
        show_error(error)
      end

      def profiles_dialog
        content = Zaniah::Div.new.flex_col.gap(8)
        @profiles.names.each do |name|
          row = Zaniah::Div.new.flex_row.gap(6)
            .child(Zaniah::UI::Button.new(name, variant: name == @profiles.active ? :secondary : :ghost).on_click { switch_profile(name) }.flex_1)
            .child(Zaniah::UI::Button.new(t("複製")).on_click { path_dialog(t("新しいプロファイル名")) { |value| @profiles.create(value, copy_from: name); profiles_dialog } })
          row.child(Zaniah::UI::Button.new(t("削除")).disabled(name == @profiles.active || name == "default").on_click { @profiles.delete(name); profiles_dialog })
          content.child(row)
        end
        content.child(Zaniah::UI::Button.new(t("新規作成")).on_click { path_dialog(t("新しいプロファイル名")) { |value| @profiles.create(value); profiles_dialog } })
        show_dialog(:profiles, t("プロファイル"), Zaniah::ScrollView.new.h(240).child(content), reopen: -> { profiles_dialog })
      end

      def switch_profile(name)
        raise Vanken::Error, "stop capture before switching profiles" if @capture.running?
        raise Vanken::Error, "finish loading before switching profiles" if document&.loading? && !@reanalysis_in_flight
        close_analysis if respond_to?(:close_analysis)
        @preferences = @profiles.switch(name)
        @capture.preferences = @preferences
        reset_resolver
        reload_columns
        reload_coloring_rules
        change_theme(@preferences.get("appearance.theme"), persist: false)
        rebuild_view
        dismiss_dialog
        reconfigure_analysis if document
      rescue StandardError => error
        show_error(error)
      end

      def decode_as
        field = Zaniah::UI::TextField.new(analysis_settings.decode_as.join("; "), label: t("例: udp.port==8443,dns")).test_id("vk.decode_as.rules")
        content = Zaniah::Div.new.flex_col.gap(12).child(field)
          .child(Zaniah::UI::Button.new(t("適用")).on_click do
            rules = field.value.split(";").map(&:strip).reject(&:empty?)
            Gateway::Dissector.new(decode_as: rules, plugins: analysis_settings.plugins)
            analysis_settings.decode_as = rules
            dismiss_dialog
            reconfigure_analysis
          rescue StandardError => error
            show_error(error)
          end)
        show_dialog(:decode_as, t("別プロトコルとして解析"), content, reopen: -> { decode_as })
      end

      def plugins_dialog
        content = Zaniah::Div.new.flex_col.gap(8)
        analysis_settings.plugin_entries.each do |entry|
          path = entry.fetch("path")
          content.child(Zaniah::Div.new.flex_row.gap(8).child(Zaniah::UI::Label.new(path, wrap: :word).flex_1)
            .child(Zaniah::UI::Button.new(t("削除")).on_click { analysis_settings.remove_plugin(path); plugins_dialog }))
        end
        content.child(Zaniah::UI::Button.new(t("追加")).on_click { path_dialog(t("Ruby ディセクタのパス")) { |path| analysis_settings.register_plugin(path); reload_plugins } })
        content.child(Zaniah::UI::Button.new(t("再読み込み")).on_click { reload_plugins })
        show_dialog(:plugins, t("ディセクタプラグイン"), Zaniah::ScrollView.new.h(240).child(content), reopen: -> { plugins_dialog })
      end

      def reload_plugins
        paths = analysis_settings.untrusted_plugins
        return reconfigure_analysis if paths.empty?
        content = Zaniah::Div.new.flex_col.gap(12).child(Zaniah::UI::Label.new(t("Ruby プラグインはユーザー権限で任意のコードを実行します。信頼するファイルだけを読み込んでください。\n%{paths}", paths: paths.join("\n")), wrap: :word))
          .child(Zaniah::UI::Button.new(t("信頼して読み込む")).test_id("vk.plugins.trust").on_click { analysis_settings.trust_plugins(paths); dismiss_dialog; reconfigure_analysis })
          .child(Zaniah::UI::Button.new(t("キャンセル"), variant: :secondary).on_click { dismiss_dialog })
        show_dialog(:plugin_trust, t("プラグインの確認"), content, reopen: -> { reload_plugins })
      end

      def reconfigure_analysis
        doc = document
        return unless doc
        raise Vanken::Error, "finish loading or stop capture before changing analysis" if @capture.running? || (doc.loading? && !@reanalysis_in_flight)
        @pending_reanalysis = {document: doc, options: {decode_as: analysis_settings.decode_as, plugins: analysis_settings.plugins, preferences: @preferences}, number: selected_number}
        begin_reanalysis
      end

      def begin_reanalysis
        request = @pending_reanalysis
        return unless request && !document&.loading? && (!@reanalysis_task || @reanalysis_task.done?)
        @pending_reanalysis = nil
        doc = request[:document]
        return unless document.equal?(doc) && !@closing
        close_analysis if respond_to?(:close_analysis)
        @selection_generation += 1
        selection_generation = @selection_generation
        @reanalysis_selection = nil
        @reanalysis_in_flight = true
        @active_reanalysis = request
        @packet_source.reset
        @reanalysis_task = @app.executor.background do
          doc.reanalyze(**request[:options])
          doc.cancel_reanalysis unless @active_reanalysis.equal?(request)
          doc.wait
          raise doc.error if doc.error
          @app.executor.post do
            next if @closing || !document.equal?(doc)
            @packet_source.reset
            @reanalysis_selection = [doc, request[:number], selection_generation]
            changed
          end
        rescue StandardError => error
          @app.executor.post do
            next if @closing || !document.equal?(doc)
            @reanalysis_in_flight = false
            show_error(error)
            begin_reanalysis
          end
        end
        @reanalysis_task.on_complete { @app.executor.post { changed if !@closing && document.equal?(doc) } }
      end

      def wait_reanalysis
        task, @reanalysis_task = @reanalysis_task, nil
        @active_reanalysis = nil
        document&.cancel_reanalysis if @reanalysis_in_flight && task && !task.done?
        task&.await
      end

      def apply_analysis_settings
        return unless @pending_analysis_settings
        return if @capture.running? || document&.loading?
        @pending_analysis_settings = false
        document&.cancel_scan
        @pool_mutex.synchronize do
          @pool&.shutdown
          @pool = nil
        end
        reconfigure_analysis if document
      end

      def command_palette
        dismiss_dialog
        @dialog_kind = :command_palette
        @dialog_reopen = -> { command_palette }
        @dialog = Zaniah::UI::CommandPalette.from(@app.actions, open: true, placeholder: t("コマンドを検索"), title: t("コマンドパレット"), close_label: t("閉じる")).test_id("vk.command_palette")
          .on_close { dismiss_dialog }
        @window.request_frame
      end

      def rebuild_view
        expanded = @tree&.expanded&.dup || []
        text = @filter_field.value
        @filter_field = Zaniah::UI::TextField.new(text, placeholder: t("表示フィルタ"), clearable: false).test_id("vk.filter.input")
        @filter_field.completion(CompletionProvider.new(self)).on_change { |value, _| validate_filter(value) }
        Actions.install(self)
        @main_view = MainView.new(self).test_id("vk.main")
        @tree.replace(detail_nodes)
        expanded.each { |id| @tree.expand(id) }
        @hex.bytes = selected_bytes
        @table.selection.add(selected_number) if selected_number
        @packet_source.reset
        reopen_dialog
        @window.request_frame
      end

      private

      def setting_label(path)
        label = SETTING_LABELS[path] || {"appearance" => "表示", "packet_list" => "パケット一覧", "capture" => "キャプチャ", "analysis" => "解析", "name_resolution" => "名前解決"}.fetch(path, path)
        t(label)
      end
    end
  end
end
