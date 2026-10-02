# frozen_string_literal: true
# rbs_inline: enabled

require "set"
require "json"

module Vanken
  module Core
    class InternTable
      # @rbs! @values: Array[String]
      # @rbs! @ids: Hash[String, Integer]
      # @rbs () -> void
      def initialize
        @values = [] #: Array[String]
        @ids = {} #: Hash[String, Integer]
      end
      # @rbs (String value) -> Integer
      def intern(value) = @ids.fetch(value) { @ids[value] = @values.length; @values << value.freeze; @values.length - 1 }
      # @rbs (Integer id) -> String
      def [](id) = @values.fetch(id)
    end

    class ColumnStore
      FORMAT = "L<L<L<l<l<l<Q<"
      SIZE = 32
      attr_reader :strings #: InternTable
      # @rbs! @protocol_ids: Hash[String, Integer]
      # @rbs! @protocol_names: Array[String]
      # @rbs! @transport_values: Hash[Integer, Hash[String, Array[Integer]]]
      # @rbs () -> void
      def initialize
        @strings = InternTable.new
        @data = +"".b
        @protocol_ids = {} #: Hash[String, Integer]
        @protocol_names = [] #: Array[String]
        @transport_values = {} #: Hash[Integer, Hash[String, Array[Integer]]]
      end
      # @rbs (column_values values) -> void
      def append(values)
        mask = values[:layers].reduce(0) do |bits, name|
          id = @protocol_ids.fetch(name) { @protocol_ids[name] = @protocol_names.length; @protocol_names << name; @protocol_names.length - 1 }
          raise Vanken::Error, "too many protocols in compact index" if id >= 64
          bits | (1 << id)
        end
        @data << [@strings.intern(values[:source]), @strings.intern(values[:destination]), @strings.intern(values[:protocol]),
                  values[:src_port], values[:dst_port], values[:ip_proto], mask].pack(FORMAT)
        @transport_values[@data.bytesize / SIZE] = values[:transport_values] if values[:transport_values]
      end
      # @rbs (Integer number) -> column_values
      def [](number)
        src, dst, proto, sport, dport, ipproto, mask = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {source: @strings[src], destination: @strings[dst], protocol: @strings[proto], src_port: sport, dst_port: dport, ip_proto: ipproto, layers: @protocol_names.select { |name| mask & (1 << @protocol_ids[name]) != 0 }}
      end
      # @rbs (Integer number, String name) -> bool?
      def layer?(number, name)
        id = @protocol_ids[name]
        id && (@data.byteslice(((number - 1) * SIZE) + 24, 8).unpack1("Q<") & (1 << id)) != 0
      end
      # @rbs (Integer number, String name) -> Array[Integer]
      def port_values(number, name)
        if (all = @transport_values[number])
          names = name.end_with?(".port") ? [name.sub(".port", ".srcport"), name.sub(".port", ".dstport")] : [name]
          return names.flat_map { |field| Array(all[field]) }
        end
        return [] unless layer?(number, name.split(".").first)

        row = self[number]
        name.end_with?(".port") ? [row[:src_port], row[:dst_port]].reject(&:negative?) :
          [name.end_with?("srcport") ? row[:src_port] : row[:dst_port]].reject(&:negative?)
      end
    end

    class AnnotationStore
      FLAGS = %w[retransmission out_of_order lost_segment duplicate_ack zero_window keep_alive].freeze
      FORMAT = "q<q<q<L<Cx3"
      SIZE = 32
      attr_reader :streams #: Hash[Integer, Array[Integer]]
      attr_reader :experts #: Hash[Integer, Array[Hash[Symbol, untyped]]]
      # @rbs! @extra: Hash[Integer, Hash[String, untyped]]
      # @rbs (String directory) -> void
      def initialize(directory)
        @data = +"".b
        @extra, @streams, @experts = {}, Hash.new { |hash, key| hash[key] = [] }, {}
        @io = File.open(File.join(directory, "annotations.bin"), "wb", 0o600)
      end
      # @rbs (Integer number, annotation_values annotation) -> void
      def append(number, annotation)
        flags = FLAGS.each_with_index.sum { |name, index| annotation[:analysis_flags].include?(name) ? 1 << index : 0 }
        record = [annotation[:tcp_stream], annotation[:seq_rel], annotation[:ack_rel], flags, annotation[:expert_max]].pack(FORMAT)
        @data << record
        @io.write(record)
        @streams[annotation[:tcp_stream]] << number if annotation[:tcp_stream] >= 0
        @experts[number] = annotation[:expert_items] unless annotation[:expert_items].empty?
        @extra[number] = annotation[:extra] unless annotation[:extra].empty?
      end
      # @rbs (Integer number) -> annotation_values
      def [](number)
        stream, seq, ack, flags, expert = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {tcp_stream: stream, seq_rel: seq, ack_rel: ack, expert_max: expert,
         analysis_flags: FLAGS.each_with_index.filter_map { |name, index| name if flags & (1 << index) != 0 },
         expert_items: @experts.fetch(number, []), extra: @extra.fetch(number) { Hash.new }}
      end
      # @rbs () -> void
      def flush = @io.flush
      # @rbs (String path) -> String
      def snapshot(path)
        flush
        File.open(path, "w", 0o600) { |io| io.write(JSON.generate("experts" => @experts, "extras" => @extra)) }
        path
      end
      # @rbs () -> void
      def close = @io.close
    end

    class RowCache
      # @rbs! @entries: Hash[untyped, untyped]
      # @rbs (?limit: Integer) -> void
      def initialize(limit: 20_000)
        @limit = limit
        @entries = {} #: Hash[untyped, untyped]
        @mutex = Mutex.new
      end
      # @rbs [T] (untyped key) { () -> T } -> T
      def fetch(key)
        cached = @mutex.synchronize { value = @entries.delete(key); @entries[key] = value if value; value }
        return cached if cached
        value = yield
        @mutex.synchronize { @entries[key] = value; @entries.shift while @entries.size > @limit }
        value
      end
      # @rbs () -> void
      def clear = @mutex.synchronize { @entries.clear }
    end
  end
end
