# frozen_string_literal: true

require_relative "../core/coloring"

module Vanken
  module UI
    module ColoringOperations
      def coloring_rules = @coloring_rules ||= load_coloring_rules
      def reload_coloring_rules
        @coloring_rules = load_coloring_rules
        @packet_source.reset
        @window.request_frame
      end
      def replace_coloring_rules(payload)
        rules = Core::Coloring::RuleSet.new(payload, catalog: document&.catalog)
        rules.save(File.join(@preferences.directory, "coloring_rules.yml"))
        @coloring_rules = rules
        @packet_source.reset
        @window.request_frame
        rules
      end
      def coloring_enabled? = @preferences.get("packet_list.coloring")
      def toggle_coloring
        @preferences.set("packet_list.coloring", !coloring_enabled?)
        @packet_source.reset
        @window.request_frame
      end

      def coloring_dialog
        @coloring_draft ||= coloring_rules.to_h
        rules = @coloring_draft.fetch("rules")
        @coloring_index = (@coloring_index || 0).clamp(0, [rules.size - 1, 0].max)
        content = Zaniah::Div.new.flex_col.gap(12)
        unless rules.empty?
          content.child(Zaniah::UI::Select.new(rules.each_with_index.map { |rule, index| ["#{index + 1}. #{rule.fetch('name')}", index] }, label: t("ルール"), value: @coloring_index)
            .on_change { |value, *_| @coloring_index = value; coloring_dialog }.test_id("vk.coloring.rule"))
          rule = rules[@coloring_index]
          content.child(Zaniah::UI::TextField.new(rule.fetch("name"), label: t("名前")).on_change { |value, *_| rule["name"] = value }.test_id("vk.coloring.name"))
          content.child(Zaniah::UI::TextField.new(rule.fetch("filter"), label: t("表示フィルタ")).on_change { |value, *_| rule["filter"] = value }.test_id("vk.coloring.filter"))
          content.child(Zaniah::UI::Checkbox.new(t("有効"), value: rule.fetch("enabled")).on_change { |value, *_| rule["enabled"] = value })
          %w[light dark].each do |theme|
            content.child(Zaniah::Div.new.flex_row.gap(12).children(%w[fg bg].map do |key|
              label = t("%{theme} %{part}", theme: t(theme == "light" ? "ライト" : "ダーク"), part: t(key == "fg" ? "文字" : "背景"))
              Zaniah::UI::ColorPicker.new(rule.fetch(theme).fetch(key), label: label).on_change { |value, *_| rule.fetch(theme)[key] = value }.flex_1
            end))
          end
          content.child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Button.new(t("上へ移動"), variant: :secondary).disabled(@coloring_index.zero?).on_click { move_coloring_rule(-1) })
            .child(Zaniah::UI::Button.new(t("下へ移動"), variant: :secondary).disabled(@coloring_index == rules.size - 1).on_click { move_coloring_rule(1) })
            .child(Zaniah::UI::Button.new(t("削除"), variant: :secondary).on_click { rules.delete_at(@coloring_index); coloring_dialog }))
        end
        content.child(Zaniah::Div.new.flex_row.gap(8)
          .child(Zaniah::UI::Button.new(t("追加"), variant: :secondary).on_click do
            rules << {"name" => t("新しいルール"), "filter" => "tcp", "enabled" => true, "light" => {"fg" => "#12272E", "bg" => "#E7E6FF"}, "dark" => {"fg" => "#E7E6FF", "bg" => "#24233A"}}
            @coloring_index = rules.size - 1
            coloring_dialog
          end)
          .child(Zaniah::UI::Button.new(t("インポート"), variant: :secondary).on_click { import_coloring_rules })
          .child(Zaniah::UI::Button.new(t("エクスポート"), variant: :secondary).on_click { export_coloring_rules }))
        content.child(Zaniah::Div.new.flex_row.gap(8)
          .child(Zaniah::UI::Button.new(t("適用")).test_id("vk.coloring.apply").on_click do
            replace_coloring_rules(@coloring_draft)
            @coloring_draft = nil
            dismiss_dialog
          rescue StandardError => error
            show_error(error)
          end)
          .child(Zaniah::UI::Button.new(t("キャンセル"), variant: :secondary).on_click { @coloring_draft = nil; dismiss_dialog }))
        viewport = Zaniah::ScrollView.new.h([(@window.content_size.height * 0.9) - 100, 120].max).child(content)
        show_dialog(:coloring, t("色付けルール"), viewport, reopen: -> { coloring_dialog })
      end

      def import_coloring_rules
        path_dialog(t("色付けルールの読み込み先")) do |path|
          @coloring_draft = Core::Coloring::RuleSet.load(path, catalog: document&.catalog).to_h
          @coloring_index = 0
          coloring_dialog
        end
      end
      def export_coloring_rules
        path_dialog(t("色付けルールの保存先")) do |path|
          Core::Coloring::RuleSet.new(@coloring_draft || coloring_rules.to_h, catalog: document&.catalog).save(path)
          coloring_dialog
        end
      end

      private
      def load_coloring_rules
        path = File.join(@preferences.directory, "coloring_rules.yml")
        File.file?(path) ? Core::Coloring::RuleSet.load(path, catalog: document&.catalog) : Core::Coloring::RuleSet.defaults(catalog: document&.catalog)
      rescue Vanken::ConfigError => error
        show_error(error)
        Core::Coloring::RuleSet.defaults(catalog: document&.catalog)
      end
      def move_coloring_rule(delta)
        rules = @coloring_draft.fetch("rules")
        target = @coloring_index + delta
        rules[@coloring_index], rules[target] = rules[target], rules[@coloring_index]
        @coloring_index = target
        coloring_dialog
      end
    end
  end
end
