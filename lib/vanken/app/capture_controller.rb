# frozen_string_literal: true

require_relative "../errors"
require_relative "../capture/launcher"
require_relative "../capture/control_protocol"
require_relative "../gateway/file_reader"
require_relative "document"

module Vanken
  module App
    class CaptureController
      class Error < Vanken::CaptureError
        attr_reader :code

        def initialize(message, code: "internal")
          @code = code
          super(message)
        end
      end

      def initialize(launcher: nil, preferences: nil, on_update: nil, on_document: nil)
        @preferences, @on_update, @on_document = preferences, on_update, on_document
        @launcher = launcher || Capture::Launcher.new(strategy: preferences&.get("capture.launcher") || :auto)
        @mutex = Mutex.new
        @state, @stats = :idle, {}
      end

      def state = @mutex.synchronize { @state }
      def stats = @mutex.synchronize { @stats.dup }
      def error = @mutex.synchronize { @error }
      def warning = @mutex.synchronize { @warning }
      def document = @mutex.synchronize { @document }
      def options = @mutex.synchronize { @options&.dup }
      def capturing? = state == :capturing
      def running? = @mutex.synchronize { !!@worker&.alive? }
      def snapshot = @mutex.synchronize { {state: @state, stats: @stats.dup, error: @error, warning: @warning, document: @document} }

      def start(options)
        @mutex.synchronize do
          raise Error, "capture controller is closed" if @closed
          raise Error, "capture is already running" if @worker&.alive?

          @options = if options.is_a?(Hash)
                       defaults = @preferences&.get("capture") || {}
                       defaults.merge(options.transform_keys(&:to_s)).reject { |key, _| key == "launcher" }
                     else
                       options.dup
                     end
          @options = if @options.is_a?(Hash)
                       @options.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
                     else
                       @options.map { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
                     end
          @state, @stats, @error, @warning = :starting, {}, nil, nil
          @stop_requested, @started, @stopped_event, @handle, @stopper = false, false, false, nil, nil
          @worker = thread { run }
        end
        notify
        self
      end

      def stop
        changed = @mutex.synchronize do
          next false unless @worker&.alive?

          @stop_requested = true
          @state = :stopping unless @state == :failed
          stop_helper
          true
        end
        notify if changed
        self
      end

      def wait(timeout = nil, **options)
        timeout = options.fetch(:timeout, timeout)
        worker = @mutex.synchronize { @worker }
        !worker || worker.join(timeout) ? self : nil
      end
      alias await wait

      def close
        @mutex.synchronize { @closed = true }
        stop.wait
        document&.close
        self
      end

      private

      def run
        handle = @launcher.launch(@options)
        @mutex.synchronize do
          @handle = handle
          stop_helper if @stop_requested
        end
        control = thread { consume_control(handle.stderr) }
        doc = Document.new(preferences: @preferences, on_update: @on_update)
        @mutex.synchronize { @document = doc }
        @on_document&.call(doc)
        reader = Gateway::FileReader.new(handle.stdout)
        doc.ingest(reader, live: true)
        doc.wait
        unless control.join(3)
          fail_capture(Error.new("capture stdout closed before the helper stopped"))
          stop
          control.join
        end
        status = handle.wait(timeout: 3) || handle.stop(timeout: 3)
        raise Error, doc.error.message if doc.error
        unless @mutex.synchronize { @error || (@started && @stopped_event && status&.success?) }
          raise Error, "capture helper closed without a stopped message"
        end
        completed = true
      rescue StandardError => error
        fail_capture(error)
      ensure
        if handle
          @mutex.synchronize { stop_helper } unless handle.status
          @stopper&.join
        end
        control&.join
        doc&.wait
        reader&.close unless doc
        handle&.close
        @mutex.synchronize do
          @handle = nil
          @state = @error || !completed ? :failed : :stopped
        end
        notify
      end

      def consume_control(io)
        while (line = io.gets(Capture::ControlProtocol::MAX_LINE_BYTES + 1))
          event = Capture::ControlProtocol.parse(line)
          next unless event

          case event["type"]
          when "started"
            @mutex.synchronize do
              @started = true
              @state = :capturing unless @stop_requested || @error
            end
          when "stats"
            @mutex.synchronize { @stats = event.reject { |key, _| %w[v type].include?(key) }.transform_keys(&:to_sym) }
          when "warning"
            @mutex.synchronize { @warning = event["message"] }
          when "error"
            if event["fatal"] != false
              fail_capture(Error.new(event["message"].to_s, code: event["code"].to_s), replace: true)
              stop
            else
              @mutex.synchronize { @warning = event["message"] }
            end
          when "stopped"
            @mutex.synchronize do
              @stopped_event = true
              @stats = event["stats"].transform_keys(&:to_sym) if event["stats"].is_a?(Hash)
            end
          end
          notify
        end
        unless @mutex.synchronize { @stopped_event || @error }
          fail_capture(Error.new("capture control channel closed without a stopped message"))
          stop
        end
      end

      # Called under @mutex; the helper stop runs separately so UI callbacks never wait for it.
      def stop_helper
        return unless @handle && !@stopper

        handle = @handle
        @stopper = thread { handle.stop(timeout: 3) }
      end

      def fail_capture(error, replace: false)
        @mutex.synchronize do
          @error = error.is_a?(Error) ? error : Error.new(error.message) if replace || !@error
          @state = :failed
        end
        notify
      end

      def thread(&block)
        Thread.new do
          Thread.current.report_on_exception = false
          block.call
        rescue StandardError => error
          fail_capture(error)
        end
      end

      def notify = @on_update&.call(self)
    end
  end
end
