# frozen_string_literal: true

module Vanken
  module UI
    module Dialogs
      def dialog = @dialog
      def dismiss_dialog
        close_analysis if respond_to?(:close_analysis)
        @dialog&.close
        @dialog = @dialog_kind = @pending_destructive = @dialog_reopen = nil
        @window.request_frame
      end
      def reopen_dialog
        @dialog_reopen&.call
      end
      def show_dialog(kind, title, content, reopen: nil)
        dismiss_dialog
        @dialog_kind = kind
        @dialog_reopen = reopen
        @dialog = Zaniah::UI::Dialog.new(content, title: title, close_label: t("閉じる")).on_close { dismiss_dialog }.test_id("vk.#{kind}")
        @window.request_frame
      end
      def path_dialog(title, value: "", &operation)
        field = Zaniah::UI::TextField.new(value, label: t(title)).test_id("vk.path.input")
        content = Zaniah::Div.new.flex_col.gap(12).child(field)
          .child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Button.new("OK").on_click do
              next if field.value.empty?
              operation.call(field.value)
            rescue StandardError => error
              show_error(error)
            end)
            .child(Zaniah::UI::Button.new(t("キャンセル"), variant: :secondary).on_click { dismiss_dialog }))
        show_dialog(:path, t(title), content, reopen: -> { path_dialog(title, value: field.value, &operation) })
      end
      def capture_options(interface: nil, values: {})
        fields = {}
        infos = @interface_infos || []
        choices = infos.map { |item| ["#{item.fetch(:name)}  #{item[:description]}", item.fetch(:name)] }
        selected = choices.any? { |choice| choice.last == interface } ? interface : choices.first&.last
        selector = Zaniah::UI::Select.new(choices, label: t("インタフェース"), value: selected)
        selector.on_change { |value, *_| selected = value }
        content = Zaniah::Div.new.flex_col.gap(10).child(selector)
        [["filter", t("キャプチャフィルタ (BPF)"), ""], ["snaplen", "Snaplen", @preferences.get("capture.snaplen").to_s],
          ["buffer_size", t("バッファサイズ (bytes)"), @preferences.get("capture.buffer_size").to_s]].each do |key, label, value|
          fields[key] = Zaniah::UI::TextField.new(values.fetch(key, value), label: label)
          content.child(fields[key])
        end
        advanced = Zaniah::Div.new.flex_col.gap(6)
        {"stop_count" => t("停止件数 (0: 無制限)"), "stop_duration" => t("停止までの秒数 (0: 無制限)"), "stop_bytes" => t("停止サイズ (bytes、0: 無制限)"),
          "ring_path" => t("リング保存先 (空欄: 保存しない)"), "ring_max_bytes" => t("リングファイル上限 (bytes)"), "ring_interval" => t("リング切替間隔 (秒)"), "ring_file_count" => t("リングファイル数")}.each do |key, label|
          fields[key] = Zaniah::UI::TextField.new(values.fetch(key, @preferences.get("capture.#{key}").to_s), label: label).test_id("vk.capture.#{key}")
          advanced.child(fields[key])
        end
        content.child(Zaniah::ScrollView.new.h(160).child(advanced))
        promiscuous = Zaniah::UI::Checkbox.new(t("プロミスキャスモード"), value: values.fetch("promiscuous", @preferences.get("capture.promiscuous")))
        content.child(promiscuous)
        direction = values.fetch("direction", @preferences.get("capture.direction"))
        content.child(Zaniah::UI::Select.new([[t("送受信"), "inout"], [t("受信"), "in"], [t("送信"), "out"]], label: t("方向"), value: direction).on_change { |value, *_| direction = value })
        status = Zaniah::UI::Label.new(infos.empty? ? (@interface_error || t("インタフェースを取得中です。")) : t("GUI は通常ユーザーで動作し、取得ヘルパーに必要な権限を渡します。"), wrap: :word, tone: :muted)
        content.child(status)
        content.child(Zaniah::UI::Button.new(t("開始")).test_id("vk.capture.start").disabled(infos.empty?).on_click do
          options = {"interface" => selected, "snaplen" => Integer(fields.fetch("snaplen").value, 10),
            "buffer_size" => Integer(fields.fetch("buffer_size").value, 10), "filter" => fields.fetch("filter").value,
            "promiscuous" => promiscuous.value, "direction" => direction, "backend" => @preferences.get("capture.backend")}
          %w[stop_count stop_bytes ring_max_bytes ring_file_count].each { |key| options[key] = Integer(fields.fetch(key).value, 10) }
          %w[stop_duration ring_interval].each { |key| options[key] = Float(fields.fetch(key).value) }
          options["ring_path"] = fields.fetch("ring_path").value
          # Compilation and privileged helper startup both happen away from the UI thread.
          @app.executor.background do
            metadata = infos.find { |item| item[:name] == selected }
            Gateway::CaptureFilter.compile(options["filter"], linktype: metadata.fetch(:linktype), live: RUBY_PLATFORM.include?("linux"), snaplen: options["snaplen"]) unless options["filter"].empty?
            @app.executor.post { start_capture(options) unless @closing }
          rescue StandardError => error
            @app.executor.post { show_error(error) unless @closing }
          end
        rescue ArgumentError => error
          show_error(error)
        end)
        show_dialog(:capture_options, t("キャプチャオプション"), content, reopen: -> { capture_options(interface: selected, values: fields.transform_values(&:value).merge("promiscuous" => promiscuous.value, "direction" => direction)) })
      end
      def preferences_dialog
        theme = Zaniah::UI::Select.new({"システム設定" => "system", "ダーク" => "dark", "ライト" => "light", "ハイコントラスト" => "high_contrast"}.map { |label, value| [t(label), value] }, label: t("テーマ"), value: @preferences.get("appearance.theme"))
          .on_change { |value, *_| change_theme(value) }
        time = Zaniah::UI::Select.new({"相対時刻" => "relative", "絶対時刻" => "absolute", "前パケットとの差" => "delta", "前表示パケットとの差" => "delta_displayed", "エポック時刻" => "epoch"}.map { |label, value| [t(label), value] }, label: t("時刻表示"), value: @preferences.get("packet_list.time_format"))
          .on_change { |value, *_| time_format(value) }
        content = Zaniah::Div.new.flex_col.gap(12).child(theme).child(time)
          .child(Zaniah::Div.new.flex_row.gap(8).child(Zaniah::UI::Button.new(t("文字を小さく")).on_click { zoom(-1) })
            .child(Zaniah::UI::Button.new(t("文字を大きく")).on_click { zoom(1) }))
        show_dialog(:preferences, t("設定"), content, reopen: -> { preferences_dialog })
      end
      def columns_dialog
        content = Zaniah::Div.new.flex_col.gap(8)
        @table.columns.each_with_index do |column, index|
          content.child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Checkbox.new(column[:label], value: column[:visible]).on_change { |value, *_| @table.column_visible(column[:key], value) }.flex_1)
            .child(Zaniah::UI::Button.new(t("上へ移動"), size: :sm).disabled(index.zero?).on_click { @table.move_column(column[:key], index - 1); columns_dialog })
            .child(Zaniah::UI::Button.new(t("下へ移動"), size: :sm).disabled(index == @table.columns.size - 1).on_click { @table.move_column(column[:key], index + 1); columns_dialog }))
        end
        show_dialog(:columns, t("表示する列"), content, reopen: -> { columns_dialog })
      end
    end
  end
end
