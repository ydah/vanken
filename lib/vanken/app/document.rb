# frozen_string_literal: true
# rbs_inline: enabled

require "tempfile"
require "json"
require_relative "../core/frame_view"
require_relative "../core/display_filter/compiler"
require_relative "../capture/receiver"
require_relative "../capture/analyzer"
require_relative "../capture/analyzer_process"
require_relative "document_jobs"
require_relative "../config/analysis_settings"
require_relative "document_analysis"
require_relative "navigation"
require_relative "../config/columns"

module Vanken
  module App
    class Document
      include DocumentJobs
      include DocumentAnalysis
      include Navigation
      attr_reader :store, :columns, :annotations, :error, :path, :source, :progress, :filter,
                  :marked, :ignored, :time_references, :catalog, :analysis_options, :analysis_gateway_options
      attr_accessor :frame_latency, :scanner

      def initialize(on_update: nil, preferences: nil, store: nil, scanner: nil, process_analysis: true, decode_as: nil, plugins: nil)
        @verify_checksums = preferences&.get("analysis.verify_checksums") || false
        settings = preferences && Config::AnalysisSettings.new(directory: preferences.directory)
        @analysis_gateway_options = {verify_checksums: @verify_checksums, decode_as: decode_as || settings&.decode_as || [], plugins: plugins || settings&.plugins || []}.freeze
        @dissector = Gateway::Dissector.new(**@analysis_gateway_options)
        @store = store || Core::FrameStore.new
        @columns = Core::ColumnStore.new
        @annotations = Core::AnnotationStore.new(@store.directory)
        @cache = Core::RowCache.new(limit: preferences&.get("packet_list.row_cache_rows") || 20_000)
        @process_analysis = process_analysis
        @analysis_options = {max_state_bytes: (preferences&.get("analysis.max_state_mib") || 256) << 20,
                             max_flows: preferences&.get("analysis.max_flows") || 100_000}.freeze
        @catalog = Gateway::FieldCatalog.new(registry: @dissector.registry)
        @mutex, @condition = Mutex.new, ConditionVariable.new
        @close_mutex = Mutex.new
        @jobs, @count, @generation = [], 0, 0
        @display = nil
        @marked, @ignored, @time_references = Set.new, Set.new, Set.new
        @received, @analyzed, @cancelled, @dirty = false, false, false, false
        @on_update, @last_notify = on_update, 0.0
        @scanner = scanner
        @scan_concurrency = preferences&.get("analysis.workers") || 4
        @filter_tasks = []
        open_analysis_files
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
        @analyzer = if @process_analysis
          Capture::AnalyzerProcess.new(self, verify_checksums: @verify_checksums)
        else
          Capture::Analyzer.new(self, @dissector)
        end
        @jobs << thread { @analyzer.run }
        @jobs << thread { Capture::Receiver.new(self, source).run }
        self
      end
      def count = @mutex.synchronize { @count }
      def displayed_count = @mutex.synchronize { @display ? @display.size : @count }
      def number_at(index) = @mutex.synchronize { @display ? @display.fetch(index) : (index + 1).tap { |number| raise IndexError unless number.between?(1, @count) } }
      def display_numbers = @mutex.synchronize { @display ? @display.dup : (1..@count).to_a }
      def dirty? = @dirty || (@source == :live && @store.count > (@saved_count || 0))
      def loading? = !@analyzed && !@cancelled
      def cancelled? = @cancelled
      def received? = @received
      def complete? = @analyzed
      def closing? = !!@closing
      def analysis_stopped? = closing? || !!@reanalysis_cancelled
      def capture_stats
        value = @reader.respond_to?(:stats) && @reader.stats
        value.respond_to?(:to_h) ? value.to_h : {}
      end
      def expert_summary = @mutex.synchronize { {count: @annotations.expert_count, severity: @annotations.expert_max} }
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
        info = @cache.fetch(number) { persisted_summary(number) || persisted_details(number)&.fetch("info", nil) || packet(number).info }
        base.merge(no: number, number: number, timestamp_ns: frame[:timestamp_ns], length: frame[:original_length], info: info).merge(custom_row(number))
      end
      def custom_columns = @custom_columns || []
      def custom_columns=(columns)
        raise Vanken::ConfigError, "invalid custom columns" unless columns.is_a?(Array) && columns.size <= 64 && columns.all? do |item|
          item.is_a?(Hash) && Config::Columns.valid_field?(item["field"]) && item["key"] == "field:#{item['field']}" && [true, false].include?(item["visible"])
        end
        saved = columns.map { |item| item.slice("key", "field", "visible").transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze }.freeze
        @mutex.synchronize do
          unless saved == @custom_columns
            @custom_columns = saved
            @sort_generation = (@sort_generation || 0) + 1
          end
        end
      end
      def custom_row(number)
        fields = custom_columns.select { |item| item["visible"] }
        return {} if fields.empty?
        packet = view(number)
        resolver = Core::DisplayFilter::FieldResolver.new(@catalog)
        fields.to_h do |item|
          field = item.fetch("field")
          [item.fetch("key").to_sym, Config::Columns.display(packet.values(field), type: resolver.resolve(field).type)]
        end
      end
      def custom_sort_value(number, field)
        Config::Columns.sort_value(view(number).values(field).first, type: Core::DisplayFilter::FieldResolver.new(@catalog).resolve(field).type)
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
              next false if generation != @generation || !snapshot.equal?(@filter_context)
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
              record_live_predecessors(number, number, matched ? [number] : [], context: snapshot)
              @count = number
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
          record_live_predecessors(number, number, [])
          @count = number
          @display << number if @display && !@filter
        end
        notify
      end
      # Only immutable context for this unpublished range crosses the worker pipe.
      def analysis_configuration(first, last)
        raise Vanken::Error, "invalid analysis range" unless first.is_a?(Integer) && last.is_a?(Integer) && first.positive? && (last - first + 1).between?(1, 256)
        @mutex.synchronize do
          historical = !!@filter_context
          current = @filter_context || {marked: @marked, ignored: @ignored, references: @time_references,
            predecessors: nil, limit: @count, last_displayed: @display ? @display.last : @count}
          predecessors = if current[:live_predecessors]
            (first..last).to_h { |number| [number, displayed_predecessor(number, current)] }
          else
            current[:predecessors]&.slice(*(first..last).to_a)
          end
          snapshot = current.except(:live_predecessors, :live_predecessor_start).merge(marked: current[:marked].select { |n| n.between?(first, last) }.to_set,
            ignored: current[:ignored].select { |n| n.between?(first, last) }.to_set,
            references: current[:references].dup, predecessors: predecessors,
            unfiltered_predecessor: historical && current[:predecessors].nil? && !current[:live_predecessors])
          {expression: @filter&.expression || "", generation: @generation, snapshot: snapshot,
           historical_context: historical, context_token: @filter_context&.object_id}
        end
      end
      def publish_analysis_batch(batch, analyzer, generation, context_token: nil)
        first, last = batch.values_at(:first, :last)
        length = last - first + 1
        raise Vanken::Error, "invalid analysis batch" unless length.between?(1, 256) &&
          batch[:columns][:data].bytesize == length * Core::ColumnStore::SIZE &&
          batch[:annotations][:data].bytesize == length * Core::AnnotationStore::SIZE && batch[:summary_index].bytesize == length * 8
        loop do
          committed = @mutex.synchronize do
            raise Vanken::Error, "nonsequential analysis publication" unless first == @count + 1
            next false if generation != @generation || context_token != @filter_context&.object_id
            raise Vanken::Error, "invalid filter matches" unless batch[:matches].all? { |number| number.between?(first, last) } && batch[:matches] == batch[:matches].sort.uniq
            @columns.import(batch[:columns])
            @annotations.import(batch[:annotations])
            batch[:details].each do |number, saved|
              @detail_offsets[number] = @details.pos
              @details.write(saved)
              @detail_index.write([number, @detail_offsets[number]].pack("Q<Q<"))
            end
            base = @summaries.pos
            offsets = batch[:summary_index].unpack("Q<*").map { |offset| base + offset }.pack("Q<*")
            @summaries.write(batch[:summaries])
            @summary_index.write(offsets)
            [@annotations, @details, @detail_index, @summaries, @summary_index].each(&:flush)
            @catalog.merge(batch[:fields])
            record_live_predecessors(first, last, batch[:matches])
            @summary_count = @count = last
            @display.concat(batch[:matches]) if @display
            true
          end
          break if committed
          configuration = analysis_configuration(first, last)
          batch[:matches] = analyzer.request(configuration.merge(command: :match)).fetch(:matches)
          generation = configuration[:generation]
          context_token = configuration[:context_token]
        end
        notify
      end
      def receiving_done = (@received = true; signal)
      def analyzing_done
        @annotations.flush
        @mutex.synchronize do
          @filter_context = nil if @reanalysis_context && @filter_context.equal?(@reanalysis_context)
          @reanalysis_context = nil
          @rebuilding_filter_basis = nil
          @rebuilding = false
          @reanalysis_cancelled = false
          @analyzed = true
        end
        notify(force: true)
      end
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
      def cancel_reanalysis
        @mutex.synchronize do
          if @rebuilding
            @reanalysis_cancelled = true
            @condition.broadcast
          end
        end
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
        @close_mutex.synchronize do
          return self if @closed
          @closing = true
          cancel_search
          cancel
          cancel_scan
          wait(3)
          @annotations.close
          @details.close
          @detail_reader.close
          @detail_index.close
          @summaries.close
          @summary_index.close
          @summary_reader.close
          @summary_index_reader.close
          @store.close
          @closed = true
          self
        end
      end

      private
      def persisted_summary(number)
        return nil if number > @summary_count
        if @summary_index_reader.respond_to?(:pread)
          offset = @summary_index_reader.pread(8, (number - 1) * 8).unpack1("Q<")
          length = @summary_reader.pread(4, offset).unpack1("L<")
          length.zero? ? "" : @summary_reader.pread(length, offset + 4)
        else
          @mutex.synchronize do
            @summary_index_reader.seek((number - 1) * 8)
            offset = @summary_index_reader.read(8).unpack1("Q<")
            @summary_reader.seek(offset)
            length = @summary_reader.read(4).unpack1("L<")
            length.zero? ? "" : @summary_reader.read(length)
          end
        end
      end
      def persisted_details(number)
        @mutex.synchronize do
          offset = @detail_offsets[number]
          next nil unless offset
          @detail_reader.seek(offset)
          JSON.parse(@detail_reader.gets)
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
