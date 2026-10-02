# frozen_string_literal: true

module Vanken
  module UI
    class CompletionProvider
      def initialize(ui) = @ui = ui
      def complete(text, caret)
        before = text.byteslice(0, caret)
        prefix = before[/[a-zA-Z_][\w.]*\z/] || ""
        items = []
        if caret == text.bytesize && before == prefix
          saved = @ui.preferences.bookmarks.to_a + @ui.preferences.history.map { |expression| [expression, expression] }
          items = saved.select { |label, expression| label.start_with?(prefix) || expression.start_with?(prefix) }
            .map { |label, expression| {label: label, insert_text: expression} }
        end
        names = @ui.document&.catalog&.names || Gateway::FieldCatalog.new.names
        names += %w[frame.number frame.len frame.cap_len frame.time_relative frame.marked tcp.stream tcp.port udp.port ip.addr ipv6.addr expert.severity expert.code and or not contains matches in]
        items += names.uniq.grep(/^#{Regexp.escape(prefix)}/).map { |name| {label: name} } unless prefix.empty?
        return nil if items.empty?
        Zaniah::UI::Completion.new(range: (caret - prefix.bytesize)...caret, items: items.first(40))
      end
    end

    module FilterOperations
      def set_filter(text)
        @filter_field.buffer.replace(0...@filter_field.buffer.bytesize, text)
        validate_filter(text)
      end

      def validate_filter(text)
        @filter_generation += 1
        generation = @filter_generation
        catalog = document&.catalog
        @validation_task&.cancel
        @validation_task = @app.executor.background do
          next unless generation == @filter_generation && !@closing
          sleep(0.15)
          next unless generation == @filter_generation && !@closing
          begin
            program = Core::DisplayFilter.compile(text, catalog: catalog)
            status = text.empty? ? :none : program.warnings.empty? ? :success : :warning
            message = program.warnings.join("\n")
          rescue Core::DisplayFilter::SyntaxError => error
            status = :error
            message = "#{error.message} (位置 #{error.position + 1})"
          end
          @app.executor.post do
            @filter_field.status(status, message: message) if generation == @filter_generation && !@closing
          end
        end
      end

      def apply_filter
        doc = document
        return unless doc
        expression = @filter_field.value
        doc.apply_filter(expression)
        doc.sort(@table.sort_key, @table.sort_direction) if @table&.sort_key
        @preferences.remember_filter(expression) unless expression.empty?
        @packet_source.reset
        @window.request_frame
      rescue Core::DisplayFilter::SyntaxError => error
        @filter_field.status(:error, message: "#{error.message} (位置 #{error.position + 1})")
      end
      def initial_filter(text)
        set_filter(text)
        @pending_filter = true
        changed if document&.complete?
      end

      def clear_filter
        set_filter("")
        apply_filter
      end
      def filter_from_selection(mode = :selected, prepare: false)
        filter_from_expression(selected_node&.filter, mode, prepare: prepare)
      end
      def filter_from_expression(expression, mode = :selected, prepare: false)
        return unless expression
        negative = mode.to_s.include?("not")
        expression = "!(#{expression})" if negative
        if mode.to_s.start_with?("and", "or") && !@filter_field.value.empty?
          expression = "(#{@filter_field.value}) #{mode.to_s.start_with?('and') ? '&&' : '||'} (#{expression})"
        end
        set_filter(expression)
        apply_filter unless prepare
      end
      def selection_menu(expression)
        return Zaniah::Menu.new([]) unless expression
        %i[filter prepare].each do |kind|
          %i[selected not and and_not or or_not].each do |mode|
            name = :"#{kind}_#{mode}"
            @app.actions.register(:"context_#{name}", title: @app.actions.command(name).title) do
              filter_from_expression(expression, mode, prepare: kind == :prepare)
            end
          end
        end
        @app.actions.register(:context_copy_filter, title: "フィルタとしてコピー") { copy_text(expression) }
        Zaniah::Menu.build do
          submenu("フィルタとして適用") { %i[selected not and and_not or or_not].each { |mode| item(:"context_filter_#{mode}") } }
          submenu("フィルタを準備") { %i[selected not and and_not or or_not].each { |mode| item(:"context_prepare_#{mode}") } }
          item(:context_copy_filter)
        end
      end
      def bookmark_filter
        path_dialog("フィルタの名前") do |name|
          @preferences.bookmark(name, @filter_field.value) unless name.empty?
          dismiss_dialog
        end
      end
      def filter_history
        items = @preferences.bookmarks.map { |name, expression| [name, expression] } + @preferences.history.map { |expression| [expression, expression] }
        content = Zaniah::Div.new.flex_col.gap(4).children(items.first(60).map do |label, expression|
          Zaniah::UI::Button.new(label, variant: :ghost).on_click { set_filter(expression); apply_filter; dismiss_dialog }
        end)
        show_dialog(:history, "表示フィルタ", content)
      end
    end
  end
end
