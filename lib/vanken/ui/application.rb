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
require_relative "../gateway/interfaces"
require_relative "../gateway/capture_filter"
require_relative "../app/capture_controller"
require_relative "../config/log"

module Vanken
  module UI
    class Application
      include FileOperations, FilterOperations, Selection, Dialogs
      attr_reader :app, :window, :preferences, :table, :tree, :hex, :filter_field, :capture,
                  :dialog_kind, :packet_source, :interface_infos

      def initialize(backend: nil, preferences: Config::Preferences.new, debug: false)
        @preferences = preferences
        @log = Config::Log.open(debug: debug, directory: File.join(preferences.directory, "logs"))
        @app = Zaniah::App.new
        @entity = @app.new_entity { {document: nil, number: nil, node: nil, details: [], bytes: "".b, error: nil} }
        @selection_generation, @file_generation, @filter_generation = 0, 0, 0
        @pool_mutex = Mutex.new
        @autoscroll = false
        @backend = backend || (RUBY_PLATFORM.match?(/darwin/) ? :mac : RUBY_PLATFORM.match?(/mingw|mswin/) ? :windows : :linux)
        @filter_field = Zaniah::UI::TextField.new("", placeholder: "表示フィルタ", clearable: false).test_id("vk.filter.input")
        @filter_field.completion(CompletionProvider.new(self)).on_change { |text, _| validate_filter(text) }
        @packet_source = PacketSource.new(self)
        @capture = App::CaptureController.new(preferences: preferences,
          on_document: ->(document) { @app.executor.post { attach_document(document) unless @closing } },
          on_update: ->(*) { @app.executor.post { changed unless @closing } })
        @window = @app.open_window(backend: @backend, width: preferences.get("layout.width"), height: preferences.get("layout.height"), title: "Vanken")
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
      end

      def document = @app.read(@entity)[:document]
      def selected_number = @app.read(@entity)[:number]
      def selected_node = @app.read(@entity)[:node]
      def detail_nodes = @app.read(@entity)[:details]
      def selected_bytes = @app.read(@entity)[:bytes]
      def update
        @app.update(@entity) { |state, cx| yield(state); cx.notify }
      end
      def changed
        @packet_source.refresh
        error = document&.error || @capture.error
        @app.update(@entity) { |state, cx| state[:error] = error; cx.notify }
        show_error(error) if error && @last_error != error
        if document && @pending_filter && document.complete?
          @pending_filter = false
          apply_filter
        end
      end
      def attach_document(value)
        return if @closing
        value.scanner = ->(payload) { filter_pool.submit(payload) } if value
        @selection_generation += 1
        update { |state| state.merge!(document: value, number: nil, node: nil, details: [], bytes: "".b) }
        @packet_source.reset
        @tree&.replace([])
        @hex.bytes = "".b if @hex
        @table&.selection&.clear
        @autoscroll = !!(value && (value.source == :live || value.equal?(@capture.document)) && @preferences.get("packet_list.autoscroll"))
        @table.follow_tail = @autoscroll if @table
        @table.scroll_to(0) if @table && value&.displayed_count&.positive? && !@autoscroll
        @window.title = "Vanken#{value&.path ? " — #{File.basename(value.path)}" : ""}" if @window.respond_to?(:title=)
      end
      def run = @app.run
      def native? = !%i[headless tui].include?(@backend)
      def monospace_font = @window.text_system&.font
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
        return "キャプチャファイルを開くか、インタフェースを選んで開始してください" unless doc
        dropped = @capture.stats.fetch("dropped", @capture.stats.fetch(:dropped, 0))
        total = doc.store.durable_count
        "#{doc.loading? ? '読み込み中' : 'パケット'} #{@packet_source.packet_count} / #{total}   表示 #{@packet_source.count}   ドロップ #{dropped}#{doc.progress ? "   #{(doc.progress * 100).round}%" : ''}"
      end
      def copy_text(text) = @window.write_clipboard([Zaniah::Clipboard::Item.new({"text/plain" => text})])
      def show_error(error)
        @log.error("#{error.class}: #{error.message}")
        @last_error = error
        @dialog_kind = :error
        @dialog = Zaniah::UI::Dialog.new(Zaniah::UI::Label.new(error.message, wrap: :word), title: "操作を完了できません").test_id("vk.error")
        @window.request_frame
      end
    end
  end
end
