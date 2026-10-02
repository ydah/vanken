# frozen_string_literal: true

require_relative "../config/columns"

module Vanken
  module UI
    module ColumnOperations
      def column_settings
        if !@column_settings || @columns_directory != @preferences.directory
          @columns_directory = @preferences.directory
          @column_settings = Config::Columns.load(directory: @columns_directory, legacy: @preferences.get("layout.columns"))
        end
        @column_settings
      rescue ConfigError => error
        show_error(error)
        @column_settings = Config::Columns.new
      end

      def reload_columns
        @column_settings = nil
        column_settings
        configure_document_columns
      end

      def configure_document_columns
        document.custom_columns = column_settings.custom if document
        @packet_source.reset
      end

      def persist_columns_layout(items)
        column_settings.update_layout(items)
        column_settings.save(@preferences.directory)
        configure_document_columns
      rescue StandardError => error
        show_error(error)
      end

      def add_field_column(field, label: field, width: 120)
        if document && !Core::DisplayFilter::FieldResolver.new(document.catalog).resolve(field).known
          raise Vanken::ConfigError, "unknown field: #{field}"
        end
        key = column_settings.add(field, label: label, width: width)
        apply_columns
        key
      end

      def remove_column(key)
        column_settings.remove(key)
        apply_columns
      end

      def field_menu(node)
        menu = selection_menu(node.filter)
        return menu unless node.field
        @app.actions.register(:context_apply_column, title: column_text("列として適用")) { add_field_column(node.field) }
        added = Zaniah::Menu.build { item(:context_apply_column) }
        Zaniah::Menu.new(menu.items + added.items)
      end

      def columns_dialog
        rows = Zaniah::Div.new.flex_col.gap(6)
        @table.columns.each_with_index do |column, index|
          key = column[:key]
          width = Zaniah::UI::NumberInput.new(column[:width], min: 40, max: 4096, step: 8, label: column_text("幅"))
            .w(100).test_id("vk.columns.width.#{key}")
          width.on_change do |*_|
            amount = width.number
            if amount && amount.finite? && amount.between?(40, 4096)
              width.status(:none)
              @table.resize_column(key, amount)
            else
              width.status(:error, message: column_text("幅は40から4096の範囲で指定してください"))
            end
          end
          row = Zaniah::Div.new.flex_row.items_center.gap(6)
            .child(Zaniah::UI::Checkbox.new(column[:label], value: column[:visible]).flex_1
              .on_change { |value, *_| @table.column_visible(key, value) })
            .child(width)
            .child(Zaniah::UI::Button.new(column_text("上へ移動"), size: :sm).disabled(index.zero?).on_click { @table.move_column(key, index - 1); columns_dialog })
            .child(Zaniah::UI::Button.new(column_text("下へ移動"), size: :sm).disabled(index == @table.columns.size - 1).on_click { @table.move_column(key, index + 1); columns_dialog })
          row.child(Zaniah::UI::Button.new(column_text("削除"), size: :sm).on_click { remove_column(key); columns_dialog }) if key.to_s.start_with?("field:")
          rows.child(row)
        end
        field = Zaniah::UI::TextField.new("", label: column_text("フィールド名")).test_id("vk.columns.field")
        label = Zaniah::UI::TextField.new("", label: column_text("列名 (空欄: フィールド名)")).test_id("vk.columns.label")
        content = Zaniah::Div.new.flex_col.gap(8)
          .child(Zaniah::ScrollView.new.h(280).child(rows)).child(field).child(label)
          .child(Zaniah::UI::Button.new(column_text("追加")).test_id("vk.columns.add").on_click do
            name = field.value.strip
            add_field_column(name, label: label.value.empty? ? name : label.value)
            columns_dialog
          rescue StandardError => error
            show_error(error)
          end)
        show_dialog(:columns, column_text("表示する列"), content, reopen: -> { columns_dialog })
      end

      private

      def column_text(text) = respond_to?(:t) ? t(text) : text

      def apply_columns
        column_settings.save(@preferences.directory)
        configure_document_columns
        selected = selected_number
        rebuild_view
        index = document&.displayed_index(selected)
        if index
          @table.select(index)
          @table.scroll_to(index, align: :nearest)
        end
      end
    end
  end
end
