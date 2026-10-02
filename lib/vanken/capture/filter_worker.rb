# frozen_string_literal: true
# rbs_inline: enabled

require "json"
require "set"
require_relative "../errors"
require_relative "../core/frame_store"
require_relative "../core/stores"
require_relative "../core/display_filter/compiler"
require_relative "../gateway/dissector"

module Vanken
  module Capture
    class FilterWorker
      class Reader
        attr_reader :count

        def initialize(directory, annotations_json)
          @files = []
          @index = open_file(File.join(directory, "frames.idx"))
          @data = open_file(File.join(directory, "frames.bin"))
          @annotations = open_file(File.join(directory, "annotations.bin"))
          @count = @index.size / Core::FrameStore::RECORD_SIZE
          detail_index = File.join(directory, "reassembled.idx")
          if File.file?(detail_index)
            offsets = open_file(detail_index)
            @detail_offsets = read_exact(offsets, (offsets.size / 16) * 16, 0).unpack("Q<*").each_slice(2).to_h
            @details = open_file(File.join(directory, "details.jsonl"))
          end
          interface_path = File.join(directory, "interfaces.json")
          @interfaces = File.file?(interface_path) ? JSON.parse(File.read(interface_path)) : []
          @sparse = File.file?(annotations_json) ? JSON.parse(File.read(annotations_json)) : {}
        rescue StandardError
          close
          raise
        end

        def metadata(number)
          raise IndexError, "invalid frame number" unless number.is_a?(Integer) && number.between?(1, count)

          offset, caplen, original, timestamp, linktype, interface, direction =
            read_exact(@index, Core::FrameStore::RECORD_SIZE, (number - 1) * Core::FrameStore::RECORD_SIZE).unpack(Core::FrameStore::RECORD)
          raise IOError, "invalid frame spool record" unless caplen <= 16 << 20 && caplen <= original && offset + caplen <= @data.size && direction <= 2

          {offset: offset, caplen: caplen, original_length: original, timestamp_ns: timestamp,
           linktype: linktype, interface: interface == 0xffff ? nil : @interfaces.fetch(interface),
           direction: [nil, :in, :out].fetch(direction), number: number}
        end

        def frame(number)
          values = metadata(number)
          bytes = read_exact(@data, values.delete(:caplen), values.delete(:offset))
          Core::Frame.new(**values, bytes: bytes)
        end

        def annotation(number)
          stream, seq, ack, flags, severity =
            read_exact(@annotations, Core::AnnotationStore::SIZE, (number - 1) * Core::AnnotationStore::SIZE).unpack(Core::AnnotationStore::FORMAT)
          experts = @sparse.fetch("experts", {}).fetch(number.to_s, [])
          {tcp_stream: stream, seq_rel: seq, ack_rel: ack, expert_max: severity, expert_items: experts,
           analysis_flags: Core::AnnotationStore::FLAGS.each_with_index.filter_map { |name, index| name if flags & (1 << index) != 0 },
           extra: @sparse.fetch("extras", {}).fetch(number.to_s, {})}
        end

        def packet_snapshot(number)
          offset = @detail_offsets && @detail_offsets[number]
          return nil unless offset
          raise IOError, "invalid reassembled packet offset" unless offset < @details.size

          @details.seek(offset)
          record = JSON.parse(@details.gets || raise(IOError, "truncated reassembled packet snapshot"))
          Gateway::PacketSnapshot.from_h(record.fetch("packet"))
        end

        def close = @files&.each { |io| io.close unless io.closed? }

        private

        def open_file(path)
          File.open(path, "rb").tap { |io| @files << io }
        end

        def read_exact(io, length, offset)
          return "".b if length.zero?

          value = if io.respond_to?(:pread)
            io.pread(length, offset)
          else
            io.seek(offset)
            io.read(length)
          end
          raise IOError, "truncated filter spool" unless value && value.bytesize == length

          value
        rescue EOFError
          raise IOError, "truncated filter spool"
        end
      end

      class View
        def initialize(reader, number, dissector, context)
          @reader, @number, @dissector, @context = reader, number, dissector, context
          @metadata = reader.metadata(number)
        end

        def layer?(name) = packet.layer?(name)
        def field_type(name) = packet.field_type(name)

        def values(name)
          case name
          when "frame.number" then [@number]
          when "frame.len" then [@metadata[:original_length]]
          when "frame.cap_len" then [@metadata[:caplen]]
          when "frame.time_epoch" then [@metadata[:timestamp_ns] / 1e9]
          when "frame.time_relative"
            reference = @context[:references].reverse.find { |number, _| number <= @number }&.last || @context[:reference]
            [(@metadata[:timestamp_ns] - reference) / 1e9]
          when "frame.time_delta" then [delta(@number - 1)]
          when "frame.time_delta_displayed" then [delta(@context[:predecessors].fetch(@number.to_s, @number - 1))]
          when "frame.interface_name" then @metadata[:interface] ? [@metadata[:interface]["name"]].compact : []
          when "frame.direction" then @metadata[:direction] ? [@metadata[:direction].to_s] : []
          when "frame.marked" then [@context[:marked].include?(@number)]
          when "frame.ignored" then [@context[:ignored].include?(@number)]
          when "frame.protocols" then [packet.columns[:layers].join(":")]
          when "tcp.stream" then annotation[:tcp_stream] >= 0 ? [annotation[:tcp_stream]] : []
          when "tcp.seq_relative" then annotation[:seq_rel] >= 0 ? [annotation[:seq_rel]] : []
          when "tcp.ack_relative" then annotation[:ack_rel] >= 0 ? [annotation[:ack_rel]] : []
          when "tcp.analysis.flags" then annotation[:analysis_flags].empty? ? [] : [true]
          when "expert.code" then annotation[:expert_items].map { |item| item["code"] }
          when "expert.severity"
            items = annotation[:expert_items].map { |item| item["severity"] }
            items.empty? && annotation[:expert_max] > 0 ? [%w[note warning error].fetch(annotation[:expert_max] - 1)] : items
          else
            if name.start_with?("tcp.analysis.")
              return [true] if annotation[:analysis_flags].include?(name.delete_prefix("tcp.analysis."))
              return Array(annotation[:extra][name]).compact
            end
            packet.values(name)
          end
        end

        private

        def packet = @packet ||= @reader.packet_snapshot(@number) || @dissector.dissect(@reader.frame(@number))
        def annotation = @annotation ||= @reader.annotation(@number)
        def delta(previous) = previous && previous > 0 ? (@metadata[:timestamp_ns] - @reader.metadata(previous)[:timestamp_ns]) / 1e9 : 0.0
      end

      def self.call(payload)
        validate(payload)
        reader = Reader.new(payload.fetch("spool"), payload.fetch("annotations_json", File.join(payload.fetch("spool"), "annotations.json")))
        first, last = payload.values_at("from", "to")
        raise ArgumentError, "filter chunk exceeds stored frames" unless last <= reader.count + 1

        dissector = Gateway::Dissector.new(decode_as: payload.fetch("decode_as", []), plugins: payload.fetch("plugins", []))
        program = Core::DisplayFilter.compile(payload.fetch("expr"), catalog: Gateway::FieldCatalog.new)
        context = {marked: Set.new(payload.fetch("marked", [])), ignored: Set.new(payload.fetch("ignored", [])),
                   reference: payload.fetch("time_reference_ns") { reader.count.zero? ? 0 : reader.metadata(1)[:timestamp_ns] },
                   references: payload.fetch("time_references_ns", {}).map { |number, timestamp| [Integer(number), timestamp] }.sort_by(&:first),
                   predecessors: payload.fetch("displayed_predecessors", {})}
        matches = (first...last).select { |number| program.match?(View.new(reader, number, dissector, context)) }
        {"matches" => matches}
      ensure
        reader&.close
      end

      def self.validate(payload)
        raise ArgumentError, "filter worker requires an object" unless payload.is_a?(Hash)
        raise ArgumentError, "spool and expression must be strings" unless %w[spool expr].all? { |key| payload[key].is_a?(String) }
        first, last = payload.values_at("from", "to")
        raise ArgumentError, "invalid filter chunk" unless first.is_a?(Integer) && last.is_a?(Integer) && first >= 1 && last >= first
        %w[decode_as plugins].each do |key|
          values = payload.fetch(key, [])
          raise ArgumentError, "#{key} must be an array of strings" unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) }
        end
      end
      private_class_method :validate
    end
  end
end
