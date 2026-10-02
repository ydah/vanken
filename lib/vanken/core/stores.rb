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
      # @rbs () -> Integer
      def size = @values.size
      # @rbs (Integer index) -> Array[String]
      def since(index) = @values.drop(index)
    end

    class ColumnStore
      FORMAT = "L<L<L<l<l<l<Q<"
      SIZE = 32
      attr_reader :strings #: InternTable
      # @rbs! @protocol_ids: Hash[String, Integer]
      # @rbs! @protocol_names: Array[String]
      # @rbs! @transport_values: Hash[Integer, Hash[String, Array[Integer]]]
      # @rbs! @base: Integer
      # @rbs! @string_cursor: Integer
      # @rbs! @protocol_cursor: Integer
      # @rbs () -> void
      def initialize
        @strings = InternTable.new
        @data = +"".b
        @protocol_ids = {} #: Hash[String, Integer]
        @protocol_names = [] #: Array[String]
        @transport_values = {} #: Hash[Integer, Hash[String, Array[Integer]]]
        @base = @string_cursor = @protocol_cursor = 0
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
        @transport_values[@base + (@data.bytesize / SIZE)] = values[:transport_values] if values[:transport_values]
      end
      # Transfer a batch without retaining a second copy of every frame in the worker.
      # @rbs () -> Hash[Symbol, untyped]
      def drain
        batch = {data: @data, strings: @strings.since(@string_cursor), protocols: @protocol_names.drop(@protocol_cursor), transport: @transport_values}
        @base += @data.bytesize / SIZE
        @string_cursor, @protocol_cursor = @strings.size, @protocol_names.size
        @data, @transport_values = +"".b, {}
        batch
      end
      # @rbs (Hash[Symbol, untyped] batch) -> void
      def import(batch)
        raise Vanken::Error, "invalid column batch" unless batch[:data].bytesize % SIZE == 0
        batch[:strings].each { |value| @strings.intern(value) }
        batch[:protocols].each do |name|
          raise Vanken::Error, "invalid protocol dictionary" if @protocol_ids.key?(name) || @protocol_names.size >= 64
          @protocol_ids[name] = @protocol_names.length
          @protocol_names << name
        end
        @data << batch[:data]
        @transport_values.merge!(batch[:transport])
      end
      # @rbs (Integer number) -> column_values
      def [](number)
        src, dst, proto, sport, dport, ipproto, mask = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {source: @strings[src], destination: @strings[dst], protocol: @strings[proto], src_port: sport, dst_port: dport, ip_proto: ipproto, layers: @protocol_names.select { |name| mask & (1 << @protocol_ids[name]) != 0 }}
      end
      # @rbs (Integer number, String name) -> bool?
      def layer?(number, name)
        id = @protocol_ids[name]
        id && (@data.unpack1("Q<", offset: ((number - 1) * SIZE) + 24) & (1 << id)) != 0
      end
      # @rbs (Integer number, String name) -> Array[Integer]
      def port_values(number, name)
        if (all = @transport_values[number])
          names = name.end_with?(".port") ? [name.sub(".port", ".srcport"), name.sub(".port", ".dstport")] : [name]
          return names.flat_map { |field| Array(all[field]) }
        end
        protocol = if name.start_with?("tcp.")
          "tcp"
        elsif name.start_with?("udp.")
          "udp"
        else
          name.split(".").first
        end
        return [] unless layer?(number, protocol)

        offset = ((number - 1) * SIZE) + 12
        if name.end_with?(".port")
          [@data.unpack1("l<", offset: offset), @data.unpack1("l<", offset: offset + 4)].reject(&:negative?)
        else
          offset += 4 unless name.end_with?("srcport")
          [@data.unpack1("l<", offset: offset)].reject(&:negative?)
        end
      end
    end

    class AnnotationStore
      FLAGS = %w[retransmission out_of_order lost_segment duplicate_ack zero_window keep_alive].freeze
      FORMAT = "q<q<q<L<Cx3"
      SIZE = 32
      attr_reader :streams #: Hash[Integer, Array[Integer]]
      attr_reader :experts #: Hash[Integer, Array[Hash[Symbol, untyped]]]
      attr_reader :expert_count, :expert_max #: Integer
      # @rbs! @extra: Hash[Integer, Hash[String, untyped]]
      # @rbs! @io: File?
      # @rbs (String directory, ?persist: bool) -> void
      def initialize(directory, persist: true)
        @data = +"".b
        @extra, @streams, @experts = {}, Hash.new { |hash, key| hash[key] = [] }, {}
        @expert_count = @expert_max = 0
        @io = File.open(File.join(directory, "annotations.bin"), "wb", 0o600) if persist
      end
      # @rbs (Integer number, annotation_values annotation) -> void
      def append(number, annotation)
        flags = FLAGS.each_with_index.sum { |name, index| annotation[:analysis_flags].include?(name) ? 1 << index : 0 }
        record = [annotation[:tcp_stream], annotation[:seq_rel], annotation[:ack_rel], flags, annotation[:expert_max]].pack(FORMAT)
        @data << record
        @io&.write(record)
        @streams[annotation[:tcp_stream]] << number if annotation[:tcp_stream] >= 0
        @experts[number] = annotation[:expert_items] unless annotation[:expert_items].empty?
        @expert_count += annotation[:expert_items].size
        @expert_max = [@expert_max, annotation[:expert_max]].max
        @extra[number] = annotation[:extra] unless annotation[:extra].empty?
      end
      # @rbs () -> Hash[Symbol, untyped]
      def drain
        batch = {data: @data, extras: @extra, streams: @streams.transform_values { |numbers| numbers }, experts: @experts}
        @data = +"".b
        @extra, @streams, @experts = {}, Hash.new { |hash, key| hash[key] = [] }, {}
        @expert_count = @expert_max = 0
        batch
      end
      # @rbs (Hash[Symbol, untyped] batch) -> void
      def import(batch)
        raise Vanken::Error, "invalid annotation batch" unless batch[:data].bytesize % SIZE == 0
        @io&.write(batch[:data])
        @data << batch[:data]
        @extra.merge!(batch[:extras])
        @experts.merge!(batch[:experts])
        batch[:experts].each_value do |items|
          @expert_count += items.size
          items.each do |item|
            rank = {"note" => 1, "warn" => 2, "warning" => 2, "error" => 3}.fetch(item[:severity].to_s, 0)
            @expert_max = [@expert_max, rank].max
          end
        end
        batch[:streams].each { |stream, numbers| @streams[stream].concat(numbers) }
      end
      # @rbs (Integer number) -> annotation_values
      def [](number)
        stream, seq, ack, flags, expert = @data.byteslice((number - 1) * SIZE, SIZE).unpack(FORMAT)
        {tcp_stream: stream, seq_rel: seq, ack_rel: ack, expert_max: expert,
         analysis_flags: FLAGS.each_with_index.filter_map { |name, index| name if flags & (1 << index) != 0 },
         expert_items: @experts.fetch(number, []), extra: @extra.fetch(number) { Hash.new }}
      end
      # @rbs () -> void
      def flush = @io&.flush
      # @rbs (String path) -> String
      def snapshot(path)
        flush
        File.open(path, "w", 0o600) { |io| io.write(JSON.generate("experts" => @experts, "extras" => @extra)) }
        path
      end
      # @rbs () -> void
      def close = @io&.close
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
