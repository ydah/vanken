# frozen_string_literal: true

require "vanken"
require "zaniah/ui"
require "zaniah/process_pool"
require "uri"
require_relative "main_view"
require_relative "file_operations"
require_relative "filter_operations"
require_relative "selection"
require_relative "dialogs"
require_relative "actions"
require_relative "packet_source"
require_relative "navigation_operations"
require_relative "coloring_operations"
require_relative "column_operations"
require_relative "settings_operations"
require_relative "analysis_dialogs"
require_relative "../gateway/interfaces"
require_relative "../gateway/capture_filter"
require_relative "../gateway/resolver"
require_relative "../app/capture_controller"
require_relative "../config/log"
require_relative "../config/messages"
require_relative "../config/sessions"

module Vanken
  module UI
    class Application
      include FileOperations, FilterOperations, Selection, Dialogs
      include NavigationOperations, ColoringOperations
      include ColumnOperations
      include SettingsOperations
      include AnalysisDialogs
      attr_reader :app, :window, :preferences, :table, :tree, :hex, :filter_field, :capture,
                  :dialog_kind, :packet_source, :interface_infos, :interface_traffic

      def initialize(backend: nil, preferences: nil, debug: false, session_parent: nil)
        @profiles = Config::Profiles.new(directory: preferences&.directory || Config::Paths.config)
        @preferences = preferences ||= @profiles.preferences
        @log = Config::Log.open(debug: debug, directory: File.join(preferences.directory, "logs"))
        @app = Zaniah::App.new
        @entity = @app.new_entity { {document: nil, number: nil, node: nil, details: [], bytes: "".b, error: nil} }
        @selection_generation, @file_generation, @filter_generation = 0, 0, 0
        @pool_mutex = Mutex.new
        @resolver_mutex = Mutex.new
        @resolution_changes = {}
        @autoscroll = false
        @backend = backend || (RUBY_PLATFORM.match?(/darwin/) ? :mac : RUBY_PLATFORM.match?(/mingw|mswin/) ? :windows : :linux)
        @session_parent = session_parent || Dir.tmpdir
        @filter_field = Zaniah::UI::TextField.new("", placeholder: t("表示フィルタ"), clearable: false).test_id("vk.filter.input")
        @filter_field.completion(CompletionProvider.new(self)).on_change { |text, _| validate_filter(text) }
        @packet_source = PacketSource.new(self)
        @capture = App::CaptureController.new(preferences: preferences,
          on_document: ->(document) { @app.executor.post { attach_document(document) unless @closing } },
          on_update: ->(*) { @app.executor.post { changed unless @closing } })
        @window = @app.open_window(backend: @backend, width: preferences.get("layout.width"), height: preferences.get("layout.height"), title: "Vanken")
        coloring_rules
        column_settings
        unless @backend == :tui
          @window.text_system = Zaniah::TextSystem::Renderer.new
          @window.text_system.scale_factor = @window.scale_factor
        end
        @window.on_close do
          if !@closing && (@capture.running? || document&.dirty?)
            request_destructive { @closing = true; @window.close }
            false
          else
            true
          end
        end
        @window.on_state_change do |state|
          @preferences.set("layout.width", state.frame.width.to_i.clamp(320, 65_536))
          @preferences.set("layout.height", state.frame.height.to_i.clamp(240, 65_536))
        end
        Actions.install(self)
        change_theme(preferences.get("appearance.theme"), persist: false)
        @main_view = MainView.new(self).test_id("vk.main")
        @window.draw { @main_view }
        start_interface_monitor unless @backend == :headless
        show_error(Vanken::ConfigError.new(preferences.warning)) if preferences.warning
        @app.executor.background do
          infos = Gateway::Interfaces.list
          @app.executor.post do
            next if @closing
            @interface_infos = infos
            changed
            capture_options if @dialog_kind == :capture_options
          end
        rescue StandardError => error
          @app.executor.post { @interface_error = error.message; changed }
        end
        if @backend != :headless || session_parent
          @app.executor.background do
            sessions = Config::Sessions.candidates(parent: @session_parent)
            @app.executor.post { recovery_dialog(sessions) if !@closing && !sessions.empty? && !@dialog }
          end
        end
      end

      def document = @app.read(@entity)[:document]
      def t(text, **values) = Config::Messages.translate(text, language: @preferences.get("appearance.language"), **values)
      def selected_number = @app.read(@entity)[:number]
      def selected_node = @app.read(@entity)[:node]
      def detail_nodes = @app.read(@entity)[:details]
      def selected_bytes = @app.read(@entity)[:bytes]
      def update
        @app.update(@entity) { |state, cx| yield(state); cx.notify }
      end
      def changed
        return if @closing
        apply_analysis_settings
        if @reanalysis_in_flight && @reanalysis_task&.done? && document&.complete?
          @reanalysis_in_flight = false
          @packet_source.reset
        end
        if @reanalysis_selection && document&.complete? && !@reanalysis_in_flight
          saved_doc, number, generation = @reanalysis_selection
          @reanalysis_selection = nil
          number = selected_number if generation != @selection_generation
          select_packet(number) if document.equal?(saved_doc) && number && number <= document.count
        end
        begin_reanalysis if @pending_reanalysis
        refresh_analysis
        @packet_source.refresh do
          next if @closing
          error = document&.error || @capture.error
          @app.update(@entity) { |state, cx| state[:error] = error; cx.notify }
          show_error(error) if error && @last_error != error
          if document && @pending_filter && document.complete?
            @pending_filter = false
            apply_filter
          end
        end
      end
      def attach_document(value)
        return if @closing
        wait_reanalysis
        @pending_reanalysis = @reanalysis_selection = nil
        @reanalysis_in_flight = false
        close_analysis
        cancel_packet_search
        value.scanner = ->(payload) { filter_pool.submit(payload) } if value
        @selection_generation += 1
        update { |state| state.merge!(document: value, number: nil, node: nil, details: [], bytes: "".b) }
        configure_document_columns if value
        @packet_source.reset
        @tree&.replace([])
        @hex.bytes = "".b if @hex
        @table&.selection&.clear
        @autoscroll = !!(value && (value.source == :live || value.equal?(@capture.document)) && @preferences.get("packet_list.autoscroll"))
        @table.follow_tail = @autoscroll if @table
        @table.scroll_to(0) if @table && value&.displayed_count&.positive? && !@autoscroll
        @window.title = "Vanken#{value&.path ? " — #{File.basename(value.path)}" : ""}" if @window.respond_to?(:title=)
      end
      def run
        return @app.run unless @backend == :tui
        @window.on_tick { @app.executor.drain }
        @window.run
      end
      def native? = !%i[headless tui].include?(@backend)
      def monospace_font = @window.text_system.respond_to?(:font) ? @window.text_system.font : nil
      def install_panes(table, tree, hex) = (@table, @tree, @hex = table, tree, hex)
      def filter_pool
        @pool_mutex.synchronize do
          @pool ||= Zaniah::ProcessPool.new(workers: @preferences.get("analysis.workers"),
            handler: "Vanken::Capture::FilterWorker", requires: [File.expand_path("../capture/filter_worker.rb", __dir__)],
            load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
        end
      end
      def smoke
        3.times { @app.executor.drain; @window.tick }
      end
      def close
        return if @closed
        @closing = true
        stop_interface_monitor
        reset_resolver
        wait_reanalysis
        close_analysis
        cancel_packet_search
        @packet_source.reset
        @selection_generation += 1
        @filter_generation += 1
        @file_generation += 1
        @validation_task&.cancel
        @capture.close
        document&.close
        @pool&.shutdown
        @app.executor.shutdown
        @app.executor.drain
        @window.close
        @log.close
        @closed = true
      end
      def quit = request_destructive { @closing = true; @window.close }

      def change_theme(name, persist: true)
        theme = name == "system" ? Zaniah::Theme.for(@window.appearance) : Zaniah::Theme.public_send(name)
        size = @preferences.get("appearance.font_size")
        theme = theme.with(typography: theme.typography.with(size_md: size, size_sm: size - 1, size_xs: size - 2))
        @app.global(:theme, theme)
        @preferences.set("appearance.theme", name) if persist
        @packet_source.reset
        @window.request_frame
      end
      def zoom(delta = nil)
        size = delta ? (@preferences.get("appearance.font_size") + delta).clamp(8, 32) : 13
        @preferences.set("appearance.font_size", size)
        change_theme(@preferences.get("appearance.theme"), persist: false)
      end
      def time_format(name)
        @preferences.set("packet_list.time_format", name.to_s)
        @packet_source.reset
        @window.request_frame
      end
      def toggle_autoscroll
        @autoscroll = !@autoscroll
        @preferences.set("packet_list.autoscroll", @autoscroll)
        @table.follow_tail = @autoscroll if @table
        @table.scroll_to(@packet_source.count - 1, align: :end) if @autoscroll && @packet_source.count.positive?
        @window.request_frame
      end
      def autoscroll? = @autoscroll && (!@table || @table.following_tail?)
      def capture_toggle
        return @capture.stop if @capture.running?
        capture_options
      end
      def start_capture(options)
        request_destructive do
          dismiss_dialog
          old = document
          @app.executor.background { old&.close; @capture.start(options) unless @closing }
        end
      end
      def restart_capture
        request_destructive do
          old = document
          @capture.stop
          @app.executor.background { @capture.wait; old&.close; @capture.start(@capture.options) unless @closing }
        end
      end
      def status_text
        doc = document
        return t("キャプチャファイルを開くか、インタフェースを選んで開始してください") unless doc
        dropped = @capture.stats.fetch("dropped", @capture.stats.fetch(:dropped, 0))
        total = doc.store.durable_count
        t("%{label} %{count} / %{total}   表示 %{displayed}   ドロップ %{dropped}%{progress}",
          label: t(doc.loading? ? "読み込み中" : "パケット"), count: @packet_source.packet_count, total: total,
          displayed: @packet_source.count, dropped: dropped, progress: doc.progress ? "   #{(doc.progress * 100).round}%" : "")
      end
      def copy_text(text) = @window.write_clipboard([Zaniah::Clipboard::Item.new({"text/plain" => text})])
      def show_error(error)
        @log.error("#{error.class}: #{error.message}")
        @last_error = error
        dismiss_dialog
        @dialog_kind = :error
        @dialog_reopen = -> { show_error(error) }
        @dialog = Zaniah::UI::Dialog.new(Zaniah::UI::Label.new(error.message, wrap: :word), title: t("操作を完了できません"), close_label: t("閉じる")).test_id("vk.error")
          .on_close { dismiss_dialog }
        @window.request_frame
      end

      def start_interface_monitor
        return if @traffic_thread
        @traffic_mutex, @traffic_condition = Mutex.new, ConditionVariable.new
        @traffic_thread = Thread.new do
          previous, history = nil, {}
          loop do
            break if @closing
            sample = Gateway::Interfaces.sample_traffic(previous: previous, history: history)
            previous, history = sample.values_at(:previous, :history)
            post = @traffic_mutex.synchronize do
              @traffic_sample = sample
              !@traffic_posted && (@traffic_posted = true)
            end
            if post
              @app.executor.post do
                value = @traffic_mutex.synchronize { @traffic_posted = false; @traffic_sample }
                next if @closing
                @interface_traffic = value
                @app.update(@entity) { |_state, cx| cx.notify }
              end
            end
            @traffic_mutex.synchronize { @traffic_condition.wait(@traffic_mutex, 1) unless @closing }
          end
        end
      end

      def stop_interface_monitor
        return unless @traffic_thread
        @traffic_mutex.synchronize { @traffic_condition.broadcast }
        @traffic_thread.join
        @traffic_thread = nil
      end

      def resolve_address(address, document:, number:)
        resolver = @resolver_mutex.synchronize do
          next if @closing || !@preferences.get("name_resolution.enabled")
          @resolver ||= Gateway::Resolver.new(timeout: @preferences.get("name_resolution.timeout"), limit: @preferences.get("name_resolution.cache_size"))
        end
        return address unless resolver
        resolver.request(address) do |_name|
          post = @resolver_mutex.synchronize do
            next false if @closing || !resolver.equal?(@resolver)
            (@resolution_changes[document] ||= Set.new).add(number)
            !@resolution_posted && (@resolution_posted = true)
          end
          next unless post
          @app.executor.post do
            changes = @resolver_mutex.synchronize do
              saved, @resolution_changes = @resolution_changes, {}
              @resolution_posted = false
              saved
            end
            next if @closing
            numbers = changes[self.document]
            @packet_source.invalidate_rows(numbers) if numbers && !numbers.empty?
          end
        end
      end

      def reset_resolver
        old = @resolver_mutex.synchronize do
          previous, @resolver = @resolver, nil
          @resolution_changes = {}
          @resolution_posted = false
          previous
        end
        return unless old
        @closing ? old.close : @app.executor.background { old.close }
      end

      def recovery_dialog(sessions)
        content = Zaniah::Div.new.flex_col.gap(8)
        sessions.each do |directory|
          content.child(Zaniah::Div.new.flex_col.gap(4)
            .child(Zaniah::UI::Label.new(directory, wrap: :word))
            .child(Zaniah::Div.new.flex_row.gap(8)
              .child(Zaniah::UI::Button.new(t("復旧")).on_click { recover_session(directory) })
              .child(Zaniah::UI::Button.new(t("破棄"), variant: :danger).on_click do
                Config::Sessions.discard(directory, parent: @session_parent)
                remaining = sessions.reject { |value| value == directory }
                remaining.empty? ? dismiss_dialog : recovery_dialog(remaining)
              rescue StandardError => error
                show_error(error)
              end)))
        end
        show_dialog(:recovery, t("前回のキャプチャを復旧"), Zaniah::ScrollView.new.h(240).child(content), reopen: -> { recovery_dialog(sessions) })
      end

      def recover_session(directory)
        request_destructive do
          previous = document
          attach_document(nil)
          dismiss_dialog
          @file_generation += 1
          generation = @file_generation
          preferences = @preferences
          @app.executor.background do
            previous&.close
            doc = Config::Sessions.recover(directory, parent: @session_parent, preferences: preferences,
              on_update: ->(updated) { @app.executor.post { changed if !@closing && document.equal?(updated) } })
            @app.executor.post do
              if !@closing && generation == @file_generation
                attach_document(doc)
                changed
              else
                doc.close
              end
            end
          rescue StandardError => error
            @app.executor.post { show_error(error) if !@closing && generation == @file_generation }
          end
        end
      end
    end
  end
end
