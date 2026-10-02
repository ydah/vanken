# frozen_string_literal: true

require_relative "../../vanken"
require_relative "analyzer_wire"

module Vanken
  module Capture
    class AnalyzerWorker
      class Reader
        attr_accessor :limit, :interfaces
        def initialize(directory)
          @records = File.open(File.join(directory, "frames.idx"), "rb")
          @data = File.open(File.join(directory, "frames.bin"), "rb")
          @limit, @interfaces = 0, []
        end
        def metadata(number)
          raise Vanken::Error, "frame outside published range" unless number.between?(1, @limit)
          record = read_at(@records, Core::FrameStore::RECORD_SIZE, (number - 1) * Core::FrameStore::RECORD_SIZE)
          raise Vanken::Error, "truncated analysis index" unless record.bytesize == Core::FrameStore::RECORD_SIZE
          offset, caplen, original, time, link, interface, direction = record.unpack(Core::FrameStore::RECORD)
          raise Vanken::Error, "invalid analysis frame" unless caplen <= 16 << 20 && original >= caplen && direction <= 2
          {offset: offset, caplen: caplen, original_length: original, timestamp_ns: time, linktype: link,
           interface: interface == 0xffff ? nil : @interfaces.fetch(interface), direction: [nil, :in, :out].fetch(direction), number: number}
        end
        def read(number)
          meta = metadata(number)
          bytes = meta[:caplen].zero? ? "".b : read_at(@data, meta[:caplen], meta[:offset])
          raise Vanken::Error, "truncated analysis frame" unless bytes.bytesize == meta[:caplen]
          Core::Frame.new(bytes: bytes, timestamp_ns: meta[:timestamp_ns], original_length: meta[:original_length],
            linktype: meta[:linktype], interface: meta[:interface], direction: meta[:direction], number: number)
        end
        def close
          @records.close
          @data.close
        end
        private
        def read_at(io, size, offset)
          return io.pread(size, offset) if io.respond_to?(:pread)
          io.seek(offset)
          io.read(size) || "".b
        end
      end

      class Context
        attr_reader :store
        def initialize(store) = (@store = store)
        def time_value(number, _format, references:)
          reference = references.select { |value| value <= number }.max || 1
          (@store.metadata(number)[:timestamp_ns] - @store.metadata(reference)[:timestamp_ns]) / 1e9
        end
        def displayed_predecessor(number, snapshot)
          return number - 1 if snapshot[:unfiltered_predecessor]
          return snapshot[:last_displayed] || 0 if number > snapshot[:limit]
          snapshot[:predecessors] ? snapshot[:predecessors].fetch(number, 0) : number - 1
        end
      end

      def initialize(request)
        @reader = Reader.new(request.fetch(:spool))
        @dissector = Gateway::Dissector.new(verify_checksums: request.fetch(:verify_checksums))
        @analysis = Gateway::Analysis.new(registry: @dissector.registry, **request.fetch(:analysis_options))
        @columns = Core::ColumnStore.new
        @annotations = Core::AnnotationStore.new(request.fetch(:spool), persist: false)
        @catalog = Gateway::FieldCatalog.new
        @seen_fields = @catalog.names.to_set
        @context = Context.new(@reader)
        @next = 1
      end
      def analyze(request)
        first, last = request.values_at(:first, :last)
        raise Vanken::Error, "nonsequential analysis batch" unless first == @next && last >= first && last - first < 256
        @reader.limit, @reader.interfaces = last, request.fetch(:interfaces)
        @packets = []
        summaries, summary_index, details, definitions = +"".b, +"".b, {}, {}
        (first..last).each do |number|
          frame = @reader.read(number)
          begin
            packet = @dissector.dissect(frame)
            @analysis.update(packet)
            columns, annotation, info = packet.columns, packet.annotations, packet.info
            packet.fields.each do |field|
              next unless @seen_fields.add?(field.name)
              definitions[field.name] = {type: field.type, source: :dissect, protocol: field.name.split(".").first}
            end
            if packet.reassembled?
              details[number] = JSON.generate("nodes" => Gateway::DetailBuilder.new.build(packet).map(&:to_h), "info" => info,
                "packet" => Gateway::PacketSnapshot.from_packet(packet).to_h) + "\n"
            end
          rescue StandardError => error
            packet = nil
            columns = {source: "", destination: "", protocol: "Malformed", src_port: -1, dst_port: -1, ip_proto: -1, layers: []}
            annotation = {tcp_stream: -1, seq_rel: -1, ack_rel: -1, analysis_flags: [], expert_max: 3,
              expert_items: [{severity: :error, code: "vanken.internal_error", protocol: "vanken", message: error.message}], extra: {}}
            info = error.message
          end
          @packets << packet
          @columns.append(columns)
          @annotations.append(number, annotation)
          summary_index << [summaries.bytesize].pack("Q<")
          summaries << [info.bytesize].pack("L<") << info
        end
        @next = last + 1
        @catalog.merge(definitions)
        @batch = {first: first, last: last, columns: @columns.drain, annotations: @annotations.drain,
          summaries: summaries, summary_index: summary_index, details: details, fields: definitions}
        @batch.merge(matches: matches(request))
      end
      def matches(request)
        expression = request.fetch(:expression)
        return (@batch[:first]..@batch[:last]).to_a if expression.empty?
        program = Core::DisplayFilter.compile(expression, catalog: @catalog)
        snapshot = request.fetch(:snapshot).dup
        @packets.each_with_index.filter_map do |packet, index|
          number = @batch[:first] + index
          next unless packet
          matched = program.match?(Core::FrameView.new(@context, number, packet: packet, snapshot: snapshot))
          snapshot[:last_displayed] = number if matched && !request[:historical_context]
          number if matched
        end
      end
      def close
        @analysis.close
      ensure
        @reader.close
      end
      def self.run
        $stdin.binmode
        $stdout.binmode
        worker = nil
        loop do
          request = AnalyzerWire.read($stdin)
          response = case request.fetch(:command)
          when :start
            raise Vanken::Error, "duplicate analysis start" if worker
            worker = new(request)
            {pid: Process.pid}
          when :analyze then worker.analyze(request)
          when :match then {matches: worker.matches(request)}
          when :stop then break
          else raise Vanken::Error, "unknown analysis command"
          end
          AnalyzerWire.write($stdout, response)
        rescue StandardError => error
          AnalyzerWire.write($stdout, {error: "#{error.class}: #{error.message}"})
          break
        end
      ensure
        worker&.close
      end
    end
  end
end
Vanken::Capture::AnalyzerWorker.run if $PROGRAM_NAME == __FILE__
