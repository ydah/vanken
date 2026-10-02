# frozen_string_literal: true
# rbs_inline: enabled

require "tempfile"
require "json"
require_relative "../core/frame_view"
require_relative "../core/display_filter/compiler"
require_relative "../capture/receiver"
require_relative "../capture/analyzer"
require_relative "document_jobs"

module Vanken
  module App
    class Document
      include DocumentJobs
      attr_reader :store, :columns, :annotations, :error, :path, :source, :progress, :filter,
                  :marked, :ignored, :time_references, :catalog, :analysis_options
      attr_accessor :frame_latency, :scanner

      def initialize(on_update: nil, preferences: nil, store: nil, scanner: nil)
        @store = store || Core::FrameStore.new
        @columns = Core::ColumnStore.new
        @annotations = Core::AnnotationStore.new(@store.directory)
        @cache = Core::RowCache.new(limit: preferences&.get("packet_list.row_cache_rows") || 20_000)
        @dissector = Gateway::Dissector.new(verify_checksums: preferences&.get("analysis.verify_checksums") || false)
        @analysis_options = {max_state_bytes: (preferences&.get("analysis.max_state_mib") || 256) << 20,
                             max_flows: preferences&.get("analysis.max_flows") || 100_000}.freeze
        @catalog = Gateway::FieldCatalog.new
        @mutex, @condition = Mutex.new, ConditionVariable.new
        @jobs, @count, @generation = [], 0, 0
        @display = nil
        @marked, @ignored, @time_references = Set.new, Set.new, Set.new
        @received, @analyzed, @cancelled, @dirty = false, false, false, false
        @on_update, @last_notify = on_update, 0.0
        @scanner = scanner
        @scan_concurrency = preferences&.get("analysis.workers") || 4
        @filter_tasks = []
        @details = File.open(File.join(@store.directory, "details.jsonl"), "w+b", 0o600)
        @detail_index = File.open(File.join(@store.directory, "reassembled.idx"), "w+b", 0o600)
        @detail_offsets = {}
        @frame_latency = 0.0
      end

      def open(path)
        @path, @source = File.expand_path(path), :file
        ingest(Gateway::FileReader.new(@path))
      rescue Vanken::FileError => error
        fail(error)
        self
      end

      def ingest(source, live: false)
        @source ||= live ? :live : :file
        @dirty = live
        @reader = source
        @jobs << thread { Capture::Analyzer.new(self, @dissector).run }
        @jobs << thread { Capture::Receiver.new(self, source).run }
        self
      end
      def count = @mutex.synchronize { @count }
      def displayed_count = @mutex.synchronize { @display ? @display.size : @count }
      def number_at(index) = @mutex.synchronize { @display ? @display.fetch(index) : (index + 1).tap { |number| raise IndexError unless number.between?(1, @count) } }
      def display_numbers = @mutex.synchronize { @display ? @display.dup : (1..@count).to_a }
      def dirty? = @dirty
      def loading? = !@analyzed && !@cancelled
      def cancelled? = @cancelled
      def received? = @received
      def complete? = @analyzed
      def closing? = !!@closing
      def stream_frames(stream) = @mutex.synchronize { @annotations.streams[stream].dup }
      def packet(number) = @dissector.dissect(@store.read(number))
      # @rbs (Integer number) -> Gateway::PacketSnapshot?
      def packet_snapshot(number)
        saved = persisted_details(number)
        saved && Gateway::PacketSnapshot.from_h(saved.fetch("packet"))
      end
      def view(number, packet: nil, snapshot: nil) = Core::FrameView.new(self, number, packet: packet, snapshot: snapshot)
      def row(number)
        base = @mutex.synchronize { @columns[number] }
        frame = @store.metadata(number)
        info = @cache.fetch(number) { persisted_details(number)&.fetch("info", nil) || packet(number).info }
        base.merge(no: number, number: number, timestamp_ns: frame[:timestamp_ns], length: frame[:original_length], info: info)
      end
      def details(number)
        saved = persisted_details(number)
        return restore_nodes(saved.fetch("nodes")) if saved

        Gateway::DetailBuilder.new.build(packet(number), annotations: @annotations[number])
      end
      def publish(number, packet)
        committing = false
        begin
          columns, annotation = packet.columns, packet.annotations
          @catalog.observe(packet)
          saved = JSON.generate("nodes" => Gateway::DetailBuilder.new.build(packet).map(&:to_h), "info" => packet.info,
            "packet" => Gateway::PacketSnapshot.from_packet(packet).to_h) + "\n" if packet.reassembled?
          loop do
            program, generation, snapshot = @mutex.synchronize { [@filter, @generation, @filter_context] }
            matched = !program || program.match?(view(number, packet: packet, snapshot: snapshot))
            committed = @mutex.synchronize do
              next false if generation != @generation
              committing = true
              @columns.append(columns)
              @annotations.append(number, annotation)
              if saved
                @detail_offsets[number] = @details.pos
                @details.write(saved)
                @details.flush
                @detail_index.write([number, @detail_offsets[number]].pack("Q<Q<"))
                @detail_index.flush
              end
              @count = number
              @dirty = true if @source == :live
              @display << number if @display && matched
              true
            end
            break if committed
          end
        rescue StandardError => error
          # Storage errors must abort, rather than appending another record.
          raise if committing
          return publish_failure(number, error)
        end
        notify
      end
      def publish_failure(number, error)
        @mutex.synchronize do
          @columns.append(source: "", destination: "", protocol: "Malformed", src_port: -1, dst_port: -1, ip_proto: -1, layers: [])
          @annotations.append(number, tcp_stream: -1, seq_rel: -1, ack_rel: -1, analysis_flags: [], expert_max: 3,
            expert_items: [{severity: :error, code: "vanken.internal_error", protocol: "vanken", message: error.message}], extra: {})
          @count = number
          @display << number if @display && !@filter
        end
        notify
      end
      def receiving_done = (@received = true; signal)
      def analyzing_done = (@annotations.flush; @analyzed = true; notify(force: true))
      def signal = @mutex.synchronize { @condition.broadcast }
      def wait_for_frames = @mutex.synchronize { @condition.wait(@mutex, 0.05) }
      def fail(error) = (@error = error; notify(force: true))

      def time_value(number, format = :relative, references: nil)
        current = @store.metadata(number)[:timestamp_ns]
        base = case format.to_sym
        when :epoch, :absolute then 0
        when :delta then number == 1 ? current : @store.metadata(number - 1)[:timestamp_ns]
        when :delta_displayed
          displayed = display_numbers
          index = displayed.index(number)
          previous = index && index.positive? ? displayed[index - 1] : (number > count ? displayed.last : nil)
          previous ? @store.metadata(previous)[:timestamp_ns] : current
        else
          reference = (references || @time_references).select { |value| value <= number }.max || 1
          @store.metadata(reference)[:timestamp_ns]
        end
        (current - base) / 1e9
      end

      def cancel
        @cancelled = true
        @reader.stop if @reader.respond_to?(:stop)
        signal
        self
      end
      def wait(timeout = nil)
        deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
        @jobs.each do |job|
          remaining = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          raise Vanken::Error, "background operation did not stop" if remaining && remaining <= 0 && job.alive?
          raise Vanken::Error, "background operation did not stop" unless job.join(remaining && [remaining, 0].max)
        end
        self
      end
      def close
        return self if @closed
        @closing = true
        cancel
        cancel_scan
        wait(3)
        @annotations.close
        @details.close
        @detail_index.close
        @store.close
        @closed = true
        self
      end

      private
      def persisted_details(number)
        @mutex.synchronize do
          offset = @detail_offsets[number]
          next nil unless offset
          @details.seek(offset)
          JSON.parse(@details.gets)
        end
      end
      def thread(&block)
        Thread.new do
          Thread.current.report_on_exception = false
          block.call
        rescue StandardError => error
          fail(error)
        end
      end
      def notify(force: false)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return unless force || now - @last_notify >= 0.1
        @last_notify = now
        @on_update&.call(self)
      end
      def restore_nodes(nodes)
        nodes.map do |value|
          node = value.transform_keys(&:to_sym)
          Core::DetailNode.new(**node.merge(source: node[:source].to_sym, severity: node[:severity]&.to_sym, children: restore_nodes(node[:children])))
        end
      end
    end
  end
end
