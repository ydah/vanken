# frozen_string_literal: true

module Vanken
  module UI
    module FileOperations
      CAPTURE_FILTERS = [{label: "Capture files", patterns: %w[*.pcapng *.pcap]}].freeze

      def open_dialog
        if @backend == :tui
          path_dialog("ファイルを開く") { |path| open_file(path) }
        else
          paths = @window.prompt_for_paths(filters: CAPTURE_FILTERS)
          open_file(paths.first) if paths && !paths.empty?
        end
      rescue StandardError => error
        show_error(error)
      end

      def open_file(path)
        request_destructive do
          @file_generation += 1
          generation = @file_generation
          previous = document
          attach_document(nil)
          @app.executor.background do
            previous&.close
            doc = App::Document.new(preferences: @preferences, on_update: ->(updated) { @app.executor.post { changed if document.equal?(updated) } })
            @app.executor.post do
              if generation == @file_generation && !@closing
                attach_document(doc)
                @preferences.remember_file(path)
              else
                doc.close
              end
            end
            doc.open(path)
            if generation != @file_generation || @closing
              doc.close
            end
          rescue StandardError => error
            @app.executor.post { show_error(error) if generation == @file_generation && !@closing }
          end
        end
      end

      def save_dialog(after: nil)
        return unless document
        path = @backend == :tui ? nil : @window.prompt_for_paths(save: true,
          default_name: "capture.pcapng", filters: CAPTURE_FILTERS)&.first
        return path_dialog("名前を付けて保存") { |value| save_file(value, after: after) } if @backend == :tui
        save_file(path, after: after) if path
      rescue StandardError => error
        show_error(error)
      end

      def save_file(path, after: nil)
        path += ".pcapng" if File.extname(path).empty?
        doc = document
        @app.executor.background do
          doc.save(path).wait_for_save
          @app.executor.post do
            next if @closing || !document.equal?(doc)
            doc.error ? show_error(doc.error) : (dismiss_dialog; after&.call; changed)
          end
        end
      end

      def close_document
        request_destructive do
          old = document
          @file_generation += 1
          attach_document(nil)
          @app.executor.background { @capture.stop; @capture.wait; old&.close }
        end
      end

      def reload_file = document&.source == :file && document.path && open_file(document.path)

      def request_destructive(&operation)
        if @capture.running?
          @dialog_kind = :capturing
          content = Zaniah::Div.new.gap(12).child(Zaniah::UI::Label.new("キャプチャを停止してから操作してください。"))
            .child(Zaniah::UI::Button.new("停止").on_click do
              @capture.stop
              dismiss_dialog
              @app.executor.background { @capture.wait; @app.executor.post { request_destructive(&operation) unless @closing } }
            end)
          @dialog = Zaniah::UI::Dialog.new(content, title: "キャプチャ中").test_id("vk.capture.confirm")
          @window.request_frame
          return false
        end
        return operation.call unless document&.dirty?
        @pending_destructive = operation
        @dialog_kind = :unsaved
        content = Zaniah::Div.new.flex_col.gap(12)
          .child(Zaniah::UI::Label.new("このキャプチャはまだ保存されていません。"))
          .child(Zaniah::Div.new.flex_row.gap(8)
            .child(Zaniah::UI::Button.new("保存").test_id("vk.unsaved.save").on_click { save_dialog(after: @pending_destructive) })
            .child(Zaniah::UI::Button.new("破棄", variant: :danger).test_id("vk.unsaved.discard").on_click { discard_changes })
            .child(Zaniah::UI::Button.new("キャンセル", variant: :secondary).test_id("vk.unsaved.cancel").on_click { dismiss_dialog }))
        @dialog = Zaniah::UI::Dialog.new(content, title: "キャプチャを保存しますか？", close_on_scrim: false).test_id("vk.unsaved")
        @window.request_frame
        false
      end

      def discard_changes
        action = @pending_destructive
        dismiss_dialog
        action&.call
      end
    end
  end
end
