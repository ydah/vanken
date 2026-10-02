# frozen_string_literal: true

module Vanken
  module Gateway
    module FieldValues
      ALIASES = {"ip.addr" => %w[ip.src ip.dst], "ipv6.addr" => %w[ipv6.src ipv6.dst],
                 "eth.addr" => %w[eth.src eth.dst], "tcp.port" => %w[tcp.srcport tcp.dstport],
                 "udp.port" => %w[udp.srcport udp.dstport]}.freeze
      TCP_FLAGS = {"fin" => 1, "syn" => 2, "rst" => 4, "psh" => 8, "ack" => 16, "urg" => 32}.freeze

      # @rbs (String name) { (String) -> Array[untyped] } -> Array[untyped]
      def self.read(name)
        if name.start_with?("tcp.flags.") && (bit = TCP_FLAGS[name.delete_prefix("tcp.flags.")])
          return yield("tcp.flags").map { |flags| flags & bit != 0 }
        end
        ALIASES.fetch(name, [name]).flat_map { |field| yield field }.compact
      end
    end

    # A field-only copy of stateful dissection, with an explicit binary JSON representation.
    class PacketSnapshot
      attr_reader :columns #: Core::column_values
      attr_reader :annotations #: Core::annotation_values

      # @rbs (fields: Hash[String, Array[untyped]], types: Hash[String, Symbol], layers: Array[String], columns: Core::column_values, annotations: Core::annotation_values) -> void
      def initialize(fields:, types:, layers:, columns:, annotations:)
        @fields, @types, @layers = fields, types, layers
        @columns, @annotations = columns, annotations
      end

      # @rbs (PacketView packet) -> PacketSnapshot
      def self.from_packet(packet)
        groups = packet.fields.group_by(&:name)
        new(fields: groups.transform_values { |fields| fields.map(&:value) },
          types: groups.transform_values { |fields| fields.first.type }, layers: packet.columns[:layers],
          columns: packet.columns, annotations: packet.annotations)
      end

      # @rbs (Hash[String, untyped] value) -> PacketSnapshot
      def self.from_h(value)
        new(fields: decode(value.fetch("fields")), types: value.fetch("types").transform_values(&:to_sym),
          layers: value.fetch("layers"), columns: decode(value.fetch("columns")), annotations: decode(value.fetch("annotations")))
      end

      # @rbs () -> Hash[String, untyped]
      def to_h
        {"fields" => self.class.encode(@fields), "types" => @types.transform_values(&:to_s),
         "layers" => @layers, "columns" => self.class.encode(@columns), "annotations" => self.class.encode(@annotations)}
      end

      # @rbs (String name) -> Array[untyped]
      def values(name) = FieldValues.read(name) { |field| Array(@fields[field]) }
      # @rbs (String name) -> Symbol?
      def field_type(name) = @types[name]
      # @rbs (String name) -> bool
      def layer?(name) = @layers.include?(name)

      # @rbs (untyped value) -> untyped
      def self.encode(value)
        case value
        when String
          value.encoding == Encoding::UTF_8 && value.valid_encoding? ? value :
            {"$bytes" => value.unpack1("H*"), "$encoding" => value.encoding.name}
        when Symbol then {"$symbol" => value.to_s}
        when Array then value.map { |item| encode(item) }
        when Hash then {"$hash" => value.map { |key, item| [encode(key), encode(item)] }}
        when Integer, Float, TrueClass, FalseClass, NilClass then value
        else raise TypeError, "unsupported snapshot value: #{value.class}"
        end
      end

      # @rbs (untyped value) -> untyped
      def self.decode(value)
        case value
        when Array then value.map { |item| decode(item) }
        when Hash
          if value.key?("$bytes")
            [value.fetch("$bytes")].pack("H*").force_encoding(value.fetch("$encoding"))
          elsif value.key?("$symbol")
            value.fetch("$symbol").to_sym
          else
            value.fetch("$hash").to_h { |key, item| [decode(key), decode(item)] }
          end
        else value
        end
      end
    end
  end
end
