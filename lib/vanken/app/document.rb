# frozen_string_literal: true
# rbs_inline: enabled

require "tempfile"
require "json"
require_relative "../core/frame_view"
require_relative "../core/display_filter/compiler"
require_relative "../capture/receiver"
require_relative "../capture/analyzer"

module Vanken
  module App
    class Document
      attr_reader :store, :columns, :annotations, :error, :path, :source, :progress, :filter,
                  :marked, :ignored, :time_references, :catalog
      attr_accessor :frame_latency

      def initialize(on_update: nil, preferences: nil, store: nil)
        @store = store || Core::FrameStore.new
        @columns = Core::ColumnStore.new
        @annotations = Core::AnnotationStore.new(@store.directory)
        @cache = Core::RowCache.new(limit: preferences&.get("packet_list.row_cache_rows") || 20_000)
        @dissector = Gateway::Dissector.new(verify_checksums: preferences&.get("analysis.verify_checksums") || false)
        @catalog = Gateway::FieldCatalog.new
        @mutex, @condition = Mutex.new, ConditionVariable.new
        @jobs, @count, @generation = [], 0, 0
        @display = nil
        @marked, @ignored, @time_references = Set.new, Set.new, Set.new
        @received, @analyzed, @cancelled, @dirty = false, false, false, false
        @on_update, @last_notify = on_update, 0.0
        @details = File.open(File.join(@store.directory, "details.jsonl"), "w+b", 0o600)
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
      def stream_frames(stream) = @mutex.synchronize { @annotations.streams[stream].dup }
      def packet(number) = @dissector.dissect(@store.read(number))
      def view(number, packet: nil) = Core::FrameView.new(self, number, packet: packet)
      def row(number)
        base = @mutex.synchronize { @columns[number] }
        frame = @store.metadata(number)
        info = @cache.fetch(number) { packet(number).info }
        base.merge(no: number, number: number, timestamp_ns: frame[:timestamp_ns], length: frame[:original_length], info: info)
      end
      def details(number)
        offset = @mutex.synchronize { @detail_offsets[number] }
        return Gateway::DetailBuilder.new.build(packet(number), annotations: @annotations[number]) unless offset
        @mutex.synchronize do
          @details.seek(offset)
          restore_nodes(JSON.parse(@details.gets, symbolize_names: true))
        end
      end
      def publish(number, packet)
        @mutex.synchronize do
          @columns.append(packet.columns)
          @annotations.append(number, packet.annotations)
          if packet.reassembled?
            tree = Gateway::DetailBuilder.new.build(packet)
            @detail_offsets[number] = @details.pos
            @details.write(JSON.generate(tree.map(&:to_h)) + "\n")
            @details.flush
          end
          @count = number
          @display << number if @display && (!@filter || @filter.match?(view(number, packet: packet)))
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

      def apply_filter(expression)
        program = Core::DisplayFilter.compile(expression, catalog: @catalog)
        @generation += 1
        generation = @generation
        @jobs << thread do
          limit = count
          result = []
          (1..limit).each do |number|
            break if @cancelled || generation != @generation
            result << number if program.match?(view(number))
            if number % 10_000 == 0
              @progress = number.fdiv([limit, 1].max)
              notify
              Thread.pass
            end
          end
          next if @cancelled || generation != @generation
          @mutex.synchronize do
            ((limit + 1)..@count).each { |number| result << number if program.match?(view(number)) }
            @filter = expression.empty? ? nil : program
            @display = expression.empty? ? nil : result
          end
          @progress = nil
          notify(force: true)
        end
        self
      end

      def sort(key, direction = :asc)
        raise ArgumentError, "invalid sort direction" unless %i[asc desc].include?(direction)
        @jobs << thread do
          numbers = display_numbers
          values = numbers.to_h do |number|
            value = case key.to_sym
            when :no, :number then number
            when :time then @store.metadata(number)[:timestamp_ns]
            when :length then @store.metadata(number)[:original_length]
            else row(number).fetch(key.to_sym)
            end
            [number, value]
          end
          numbers.sort! { |a, b| comparison = values[a] <=> values[b]; comparison = -comparison if direction == :desc; comparison.zero? ? a <=> b : comparison }
          @mutex.synchronize { @display = numbers + (@display ? @display - numbers : ((1..@count).to_a - numbers)) }
          notify(force: true)
        end
        self
      end

      def save(path, format: nil, numbers: nil)
        @error = nil
        format ||= File.extname(path) == ".pcap" ? :pcap : :pcapng
        limit = count
        @jobs << thread do
          temporary = Tempfile.create([".vanken-", ".tmp"], File.dirname(File.expand_path(path)))
          begin
            linktype = limit.zero? ? 1 : @store.metadata(1)[:linktype]
            Gateway::FileWriter.open(temporary, format: format, linktype: linktype) do |writer|
              (numbers || (1..limit)).each { |number| writer << @store.read(number) }
            end
            temporary.flush
            temporary.fsync
            temporary.close
            File.rename(temporary.path, File.expand_path(path))
            @dirty = false unless numbers
            @path = File.expand_path(path) unless numbers
            notify(force: true)
          ensure
            temporary.close unless temporary.closed?
            File.unlink(temporary.path) if File.exist?(temporary.path)
          end
        end
        self
      end

      def time_value(number, format = :relative)
        current = @store.metadata(number)[:timestamp_ns]
        base = case format.to_sym
        when :epoch, :absolute then 0
        when :delta then number == 1 ? current : @store.metadata(number - 1)[:timestamp_ns]
        when :delta_displayed
          displayed = display_numbers
          index = displayed.index(number)
          index && index.positive? ? @store.metadata(displayed[index - 1])[:timestamp_ns] : current
        else
          reference = @time_references.select { |value| value <= number }.max || 1
          @store.metadata(reference)[:timestamp_ns]
        end
        (current - base) / 1e9
      end

      def cancel
        @cancelled = true
        @generation += 1
        @reader.stop if @reader.respond_to?(:stop)
        signal
        self
      end
      def wait(timeout = nil)
        deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @jobs.each do |job|
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Vanken::Error, "background operation did not stop" if remaining && remaining <= 0 && job.alive?
          raise Vanken::Error, "background operation did not stop" unless job.join(remaining && [remaining, 0].max)
        end
        self
      end
      def close
        cancel
        wait(3)
        @annotations.close
        @details.close
        @store.close
      end

      private
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
        nodes.map { |node| Core::DetailNode.new(**node.merge(source: node[:source].to_sym, severity: node[:severity]&.to_sym, children: restore_nodes(node[:children]))) }
      end
    end
  end
end
