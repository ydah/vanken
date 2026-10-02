# frozen_string_literal: true
# rbs_inline: enabled

require "set"

module Vanken
  module Core
    class InternTable
      def initialize = (@values = []; @ids = {})
      def intern(value) = @ids.fetch(value) { @ids[value] = @values.length; @values << value.freeze; @values.length - 1 }
      def [](id) = @values.fetch(id)
    end

    class ColumnStore
      FORMAT = "L<L<L<l<l<l<Q<"
      SIZE = 32
      attr_reader :strings
      def initialize = (@strings = InternTable.new; @data = +"".b; @protocol_ids = {}; @protocol_names = [])
      def append(values)
        mask = values[:layers].reduce(0) do |bits, name|
          id = @protocol_ids.fetch(name) { @protocol_ids[name] = @protocol_names.length; @protocol_names << name; @protocol_names.length - 1 }
          raise Vanken::Error, "too many protocols in compact index" if id >= 64
          bits | (1 << id)
        end
        @data << [@strings.intern(values[:source]), @strings.intern(values[:destination]), @strings.intern(values[:protocol]),
                  values[:src_port], values[:dst_port], values[:ip_proto], mask].pack(FORMAT)
      end
      def [](number)
        src, dst, proto, sport, dport, ipproto, mask = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {source: @strings[src], destination: @strings[dst], protocol: @strings[proto], src_port: sport, dst_port: dport, ip_proto: ipproto, layers: @protocol_names.select { |name| mask & (1 << @protocol_ids[name]) != 0 }}
      end
      def layer?(number, name)
        id = @protocol_ids[name]
        id && @data.byteslice((number - 1) * SIZE + 24, 8).unpack1("Q<") & (1 << id) != 0
      end
    end

    class AnnotationStore
      FLAGS = %w[retransmission out_of_order lost_segment duplicate_ack zero_window keep_alive].freeze
      FORMAT = "q<q<q<L<Cx3"
      SIZE = 32
      attr_reader :streams, :experts
      def initialize(directory)
        @data = +"".b
        @extra, @streams, @experts = {}, Hash.new { |hash, key| hash[key] = [] }, {}
        @io = File.open(File.join(directory, "annotations.bin"), "wb", 0o600)
      end
      def append(number, annotation)
        flags = FLAGS.each_with_index.sum { |name, index| annotation[:analysis_flags].include?(name) ? 1 << index : 0 }
        record = [annotation[:tcp_stream], annotation[:seq_rel], annotation[:ack_rel], flags, annotation[:expert_max]].pack(FORMAT)
        @data << record
        @io.write(record)
        @streams[annotation[:tcp_stream]] << number if annotation[:tcp_stream] >= 0
        @experts[number] = annotation[:expert_items] unless annotation[:expert_items].empty?
        @extra[number] = annotation[:extra] unless annotation[:extra].empty?
      end
      def [](number)
        stream, seq, ack, flags, expert = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {tcp_stream: stream, seq_rel: seq, ack_rel: ack, expert_max: expert,
         analysis_flags: FLAGS.each_with_index.filter_map { |name, index| name if flags & (1 << index) != 0 },
         expert_items: @experts.fetch(number, []), extra: @extra.fetch(number, {})}
      end
      def flush = @io.flush
      def close = @io.close
    end

    class RowCache
      def initialize(limit: 20_000) = (@limit = limit; @entries = {}; @mutex = Mutex.new)
      def fetch(key)
        cached = @mutex.synchronize { value = @entries.delete(key); @entries[key] = value if value; value }
        return cached if cached
        value = yield
        @mutex.synchronize { @entries[key] = value; @entries.shift while @entries.size > @limit }
        value
      end
      def clear = @mutex.synchronize { @entries.clear }
    end
  end
end
