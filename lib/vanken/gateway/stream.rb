# frozen_string_literal: true
# rbs_inline: enabled

require "tempfile"
require_relative "dissector"

module Vanken
  module Gateway
    StreamChunk = Data.define(
      :direction, #: Integer
      :bytes, #: String
      :missing, #: Integer
      :number, #: Integer
      :sequence #: Integer
    )
    StreamText = Data.define(
      :direction, #: Integer
      :text #: String
    )

    class Stream
      DISPLAY_LIMIT = 16 << 20 #: Integer
      SEQUENCE_MOD = 1 << 32 #: Integer
      attr_reader :nodes #: Array[String]
      attr_reader :chunks #: Array[StreamChunk]
      attr_reader :stream_id #: Integer

      # @rbs (untyped document, Integer stream_id, ?cancelled: (^() -> bool)?) -> void
      def initialize(document, stream_id, cancelled: nil)
        raise ArgumentError, "invalid stream number" unless stream_id.is_a?(Integer) && stream_id >= 0
        @stream_id, @nodes, @chunks = stream_id, [], []
        pieces = [[], []] #: Array[Array[StreamChunk]]
        starts = [nil, nil] #: Array[Integer?]
        frontiers = [0, 0]
        frames = document.stream_frames(stream_id)
        frames.each do |number|
          raise Vanken::Error, "operation cancelled" if cancelled&.call || document.closing?
          packet = document.packet(number)
          tcp = packet.layers.find { |layer| layer.protocol == :tcp && !layer.embedded }
          next unless tcp
          columns = packet.columns
          endpoints = [endpoint(columns[:source], columns[:src_port]), endpoint(columns[:destination], columns[:dst_port])]
          @nodes = tcp[:flags] & 0x12 == 0x12 ? endpoints.reverse : endpoints if @nodes.empty?
          direction = endpoints == @nodes ? 0 : 1
          sequence = document.annotations[number][:seq_rel]
          difference = (sequence - frontiers[direction]) % SEQUENCE_MOD
          difference -= SEQUENCE_MOD if difference >= SEQUENCE_MOD / 2
          sequence = frontiers[direction] + difference
          sequence += 1 if tcp[:flags] & 2 != 0
          starts[direction] ||= sequence if tcp[:flags] & 2 != 0
          data = packet.bytes.byteslice(tcp.payload_offset, tcp.payload_end - tcp.payload_offset)
          frontiers[direction] = [frontiers[direction], sequence + data.bytesize].max
          next if data.empty?
          insert(pieces[direction], StreamChunk.new(direction: direction, bytes: data, missing: 0, number: number, sequence: sequence))
        end
        directions = pieces.each_with_index.map do |segments, direction|
          cursor = starts[direction]
          segments.flat_map do |segment|
            missing = cursor && segment.sequence > cursor ? segment.sequence - cursor : 0
            cursor = segment.sequence + segment.bytes.bytesize
            gap = StreamChunk.new(direction: direction, bytes: "".b, missing: missing, number: segment.number, sequence: segment.sequence - missing)
            missing.positive? ? [gap, segment] : [segment]
          end
        end
        positions = [0, 0]
        until positions.each_with_index.all? { |index, direction| index == directions[direction].size }
          direction = [0, 1].reject { |value| positions[value] == directions[value].size }.min_by do |value|
            directions[value][positions[value]].number
          end
          raise Vanken::Error, "invalid stream direction" unless direction
          @chunks << directions[direction][positions[direction]]
          positions[direction] += 1
        end
        @nodes.freeze
        @chunks.freeze
      end

      # @rbs (?direction: Integer?) -> Integer
      def byte_size(direction: nil) = selected(direction).sum { |chunk| chunk.bytes.bytesize }

      # @rbs (?format: Symbol, ?direction: Integer?, ?limit: Integer) -> Array[StreamText]
      def preview(format: :ascii, direction: nil, limit: DISPLAY_LIMIT)
        validate(format, direction)
        raise ArgumentError, "invalid display limit" unless limit.is_a?(Integer) && limit >= 0
        remaining = limit
        result = [] #: Array[StreamText]
        selected(direction).each do |chunk|
          break if remaining.zero?
          bytes = chunk.bytes.byteslice(0, remaining) || "".b
          remaining -= bytes.bytesize
          result << StreamText.new(direction: chunk.direction, text: render(chunk, bytes, format))
        end
        result
      end

      # @rbs (String path, ?format: Symbol, ?direction: Integer?, ?cancelled: (^() -> bool)?) -> String
      def save(path, format: :raw, direction: nil, cancelled: nil)
        validate(format, direction)
        file = Tempfile.create([".vanken-stream-", ".tmp"], File.dirname(File.expand_path(path)))
        begin
          file.binmode
          selected(direction).each do |chunk|
            raise Vanken::Error, "operation cancelled" if cancelled&.call
            file.write(render(chunk, chunk.bytes, format))
          end
          file.flush
          file.fsync
          file.close
          File.rename(file.path, File.expand_path(path))
        ensure
          file.close unless file.closed?
          FileUtils.rm_f(file.path)
        end
        path
      end

      private

      # @rbs (Integer? direction) -> Array[StreamChunk]
      def selected(direction) = @chunks.select { |chunk| direction.nil? || chunk.direction == direction }
      def endpoint(address, port) = address.include?(":") ? "[#{address}]:#{port}" : "#{address}:#{port}"
      def validate(format, direction)
        raise ArgumentError, "invalid stream format" unless %i[ascii hex raw].include?(format)
        raise ArgumentError, "invalid stream direction" unless [nil, 0, 1].include?(direction)
      end

      def render(chunk, bytes, format)
        return "".b if format == :raw && chunk.missing.positive?
        return "[#{chunk.missing} bytes missing]" if chunk.missing.positive?
        return bytes if format == :raw
        return bytes.gsub(/[^\x20-\x7e\r\n\t]/n) { |byte| Kernel.format("\\x%02x", byte.getbyte(0)) } if format == :ascii
        bytes.bytes.each_slice(16).with_index.map do |row, index|
          Kernel.format("%08x  %s\n", chunk.sequence + (index * 16), row.map { |byte| Kernel.format("%02x", byte) }.join(" "))
        end.join
      end

      # Keep capture arrival precedence while inserting only previously unseen ranges.
      def insert(segments, chunk)
        first, last = chunk.sequence, chunk.sequence + chunk.bytes.bytesize
        index = segments.bsearch_index { |segment| segment.sequence + segment.bytes.bytesize > first } || segments.size
        uncovered = [] #: Array[[Integer, Integer]]
        cursor = first
        while index < segments.size && segments[index].sequence < last
          previous = segments[index]
          uncovered << [cursor, [previous.sequence, last].min] if previous.sequence > cursor
          cursor = [cursor, previous.sequence + previous.bytes.bytesize].max
          index += 1
        end
        uncovered << [cursor, last] if cursor < last
        uncovered.each do |start, finish|
          segment = chunk.with(sequence: start, bytes: chunk.bytes.byteslice(start - first, finish - start))
          position = segments.bsearch_index { |previous| previous.sequence > start } || segments.size
          # ponytail: array insertion is O(n) for heavily reordered streams; use an interval tree if measured.
          segments.insert(position, segment)
        end
      end
    end
  end
end
