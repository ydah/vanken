# frozen_string_literal: true

module Vanken
  module UI
    module Dialogs
      def dialog = @dialog
      def dismiss_dialog
        @dialog&.close
        @dialog = @dialog_kind = @pending_destructive = nil
        @window.request_frame
      end
      def show_dialog(kind, title, content)
        dismiss_dialog
        @dialog_kind = kind
        @dialog = Zaniah::UI::Dialog.new(content, title: title).on_close { dismiss_dialog }.test_id("vk.#{kind}")
        @window.request_frame
      end
      def path_dialog(title, &operation)
        field = Zaniah::UI::TextField.new("", label: title).test_id("vk.path.input")
        content = Zaniah::Div.new.flex_col.gap(12).child(field)
          .child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Button.new("OK").on_click do
              next if field.value.empty?
              operation.call(field.value)
            rescue StandardError => error
              show_error(error)
            end)
            .child(Zaniah::UI::Button.new("キャンセル", variant: :secondary).on_click { dismiss_dialog }))
        show_dialog(:path, title, content)
      end
      def capture_options(interface: nil)
        fields = {}
        infos = @interface_infos || []
        choices = infos.map { |item| ["#{item.fetch(:name)}  #{item[:description]}", item.fetch(:name)] }
        selected = choices.any? { |choice| choice.last == interface } ? interface : choices.first&.last
        selector = Zaniah::UI::Select.new(choices, label: "インタフェース", value: selected)
        selector.on_change { |value, *_| selected = value }
        content = Zaniah::Div.new.flex_col.gap(10).child(selector)
        [["filter", "キャプチャフィルタ (BPF)", ""], ["snaplen", "Snaplen", @preferences.get("capture.snaplen").to_s],
          ["buffer_size", "バッファサイズ (bytes)", @preferences.get("capture.buffer_size").to_s]].each do |key, label, value|
          fields[key] = Zaniah::UI::TextField.new(value, label: label)
          content.child(fields[key])
        end
        promiscuous = Zaniah::UI::Checkbox.new("プロミスキャスモード", value: @preferences.get("capture.promiscuous"))
        content.child(promiscuous)
        direction = @preferences.get("capture.direction")
        content.child(Zaniah::UI::Select.new([["送受信", "inout"], ["受信", "in"], ["送信", "out"]], label: "方向", value: direction).on_change { |value, *_| direction = value })
        status = Zaniah::UI::Label.new(infos.empty? ? (@interface_error || "インタフェースを取得中です。") : "GUI は通常ユーザーで動作し、取得ヘルパーに必要な権限を渡します。", wrap: :word, tone: :muted)
        content.child(status)
        content.child(Zaniah::UI::Button.new("開始").test_id("vk.capture.start").disabled(infos.empty?).on_click do
          options = {"interface" => selected, "snaplen" => Integer(fields.fetch("snaplen").value, 10),
            "buffer_size" => Integer(fields.fetch("buffer_size").value, 10), "filter" => fields.fetch("filter").value,
            "promiscuous" => promiscuous.value, "direction" => direction, "backend" => @preferences.get("capture.backend")}
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
        show_dialog(:capture_options, "キャプチャオプション", content)
      end
      def preferences_dialog
        theme = Zaniah::UI::Select.new(%w[system dark light high_contrast], label: "テーマ", value: @preferences.get("appearance.theme"))
          .on_change { |value, *_| change_theme(value) }
        time = Zaniah::UI::Select.new(%w[relative absolute delta delta_displayed epoch], label: "時刻表示", value: @preferences.get("packet_list.time_format"))
          .on_change { |value, *_| time_format(value) }
        content = Zaniah::Div.new.flex_col.gap(12).child(theme).child(time)
          .child(Zaniah::Div.new.flex_row.gap(8).child(Zaniah::UI::Button.new("文字を小さく").on_click { zoom(-1) })
            .child(Zaniah::UI::Button.new("文字を大きく").on_click { zoom(1) }))
        show_dialog(:preferences, "設定", content)
      end
      def columns_dialog
        content = Zaniah::Div.new.flex_col.gap(8)
        @table.columns.each_with_index do |column, index|
          content.child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Checkbox.new(column[:label], value: column[:visible]).on_change { |value, *_| @table.column_visible(column[:key], value) }.flex_1)
            .child(Zaniah::UI::Button.new("↑", size: :sm).disabled(index.zero?).on_click { @table.move_column(column[:key], index - 1); columns_dialog })
            .child(Zaniah::UI::Button.new("↓", size: :sm).disabled(index == @table.columns.size - 1).on_click { @table.move_column(column[:key], index + 1); columns_dialog }))
        end
        show_dialog(:columns, "表示する列", content)
      end
    end
  end
end
