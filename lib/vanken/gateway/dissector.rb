# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"
require "stringio"
require_relative "packet_snapshot"

module Vanken
  module Gateway
    PROTOCOLS = {"ip" => :ipv4}.freeze
    module Severity
      # @rbs (Symbol? value) -> Symbol?
      def self.normalize(value) = value == :warn ? :warning : value
      # @rbs (Symbol? value) -> Integer
      def self.rank(value) = {nil => 0, note: 1, warning: 2, warn: 2, error: 3}.fetch(value, 0)
    end

    class Dissector
      attr_reader :registry #: Redhound::Registry
      # @rbs (?verify_checksums: bool, ?decode_as: Array[String], ?plugins: Array[String]) -> void
      def initialize(verify_checksums: false, decode_as: [], plugins: [])
        plugins.each { |path| load File.expand_path(path) }
        @registry = Redhound::Registry.default.copy
        decode_as.each { |rule| @registry.decode_as(rule) }
        @engine = Redhound::Engine.new(registry: @registry, verify_checksums: verify_checksums)
      end
      # @rbs (Core::Frame frame) -> PacketView
      def dissect(frame)
        packet = self.class.packet(frame)
        packet.engine = @engine
        PacketView.new(packet, @registry)
      rescue Redhound::Error, ArgumentError => error
        raise Vanken::FileError, error.message
      end
      # @rbs (Core::Frame frame, ?interfaces: Hash[Hash[String, untyped], Redhound::Capture::Interface]) -> Redhound::Packet
      def self.packet(frame, interfaces: {})
        interface = frame.interface && interfaces.fetch(frame.interface) do
          values = frame.interface.transform_keys(&:to_sym).select { |key, _| %i[name index linktype snaplen flags mtu mac description filter meta].include?(key) }
          interfaces[frame.interface] = Redhound::Capture::Interface.new(name: values.fetch(:name), **values.reject { |key, _| key == :name })
        end
        Redhound.dissect(frame.bytes, linktype: frame.linktype, timestamp_ns: frame.timestamp_ns,
          original_length: frame.original_length, interface: interface, direction: frame.direction, number: frame.number)
      end
    end

    class PacketView
      attr_reader :raw_packet #: Redhound::Packet
      # @rbs (Redhound::Packet packet, Redhound::Registry registry) -> void
      def initialize(packet, registry) = (@raw_packet = packet; @registry = registry)
      # @rbs (String name) -> Array[untyped]
      def values(name) = FieldValues.read(name) { |field| @raw_packet.field_values(field) }
      # @rbs (String name) -> bool
      def layer?(name) = @raw_packet.layers.any? { |layer| layer.protocol == PROTOCOLS.fetch(name, name.to_sym) }
      # @rbs () -> Array[Redhound::Field]
      def fields = @raw_packet.layers.flat_map(&:fields)
      # @rbs (String name) -> Symbol?
      def field_type(name) = fields.find { |field| field.name == name }&.type
      # @rbs () -> Array[Redhound::Layer]
      def layers = @raw_packet.layers
      # @rbs () -> String
      def bytes = @raw_packet.data
      # @rbs () -> Hash[Symbol, untyped]
      def to_h = @raw_packet.to_h
      # @rbs () -> Array[Hash[Symbol, untyped]]
      def diagnostics
        layers.flat_map do |layer|
          layer.diagnostics.map { |item| {severity: Severity.normalize(item.severity), code: item.code.to_s,
                                         protocol: layer.protocol.to_s, message: safe_text(item.message)} }
        end
      end
      # @rbs () -> Core::column_values
      def columns
        relevant = layers.reject(&:embedded)
        network = relevant.reverse.find { |layer| %i[ipv4 ipv6].include?(layer.protocol) }
        address = network || relevant.find { |layer| layer.protocol == :arp } || relevant.find { |layer| layer.protocol == :eth }
        transport = relevant.reverse.find { |layer| %i[tcp udp].include?(layer.protocol) }
        meaning = relevant.reverse.find { |layer| !%i[data raw eth vlan ipv6_ext sll sll2 null].include?(layer.protocol) } || relevant.last
        klass = meaning && @registry.protocols[meaning.protocol]
        {source: address_text(address, :src), destination: address_text(address, :dst),
         protocol: (klass&.short_name || meaning&.protocol.to_s.upcase),
         src_port: transport&.[](:srcport) || -1, dst_port: transport&.[](:dstport) || -1,
         ip_proto: network&.[](:proto) || network&.[](:nxt) || -1,
         layers: layers.map { |layer| layer.protocol == :ipv4 ? "ip" : layer.protocol.to_s }.uniq,
         transport_values: layers.count { |layer| %i[tcp udp].include?(layer.protocol) } > 1 ?
           %w[tcp.srcport tcp.dstport udp.srcport udp.dstport].to_h { |name| [name, values(name)] } : nil}
      end
      # @rbs () -> String
      def info
        safe_text(@raw_packet.summary)
      end
      # @rbs () -> Core::annotation_values
      def annotations
        extra = fields.select { |field| field.name.start_with?("tcp.analysis.", "tcp.reassembled", "ip.reassembled") }.to_h { |field| [field.name, field.value] }
        {tcp_stream: values("tcp.stream").first || -1, seq_rel: values("tcp.seq_relative").first || -1,
         ack_rel: values("tcp.ack_relative").first || -1,
         analysis_flags: Core::AnnotationStore::FLAGS.select { |flag| values("tcp.analysis.#{flag}").any? },
         expert_max: diagnostics.map { |item| Severity.rank(item[:severity]) }.max || 0,
         expert_items: diagnostics, extra: extra}
      end
      # @rbs () -> bool
      def reassembled? = @raw_packet.meta.key?(:reassembled_packet) || fields.any? { |field| field.name == "tcp.reassembled_from" }
      # @rbs (Redhound::Layer layer) -> (:frame | :reassembled)
      def layer_source(layer)
        virtual = @raw_packet.meta[:reassembled_packet]
        return :reassembled if (virtual && virtual.layers.include?(layer)) || layer.field_value("tcp.reassembled_in")

        :frame
      end

      private
      # @rbs (untyped value) -> String
      def safe_text(value) = value.to_s.b.gsub(/[^\x20-\x7e]/n) { |byte| format("\\x%02x", byte.getbyte(0)) }
      # @rbs (Redhound::Layer? layer, Symbol direction) -> String
      def address_text(layer, direction)
        return "" unless layer
        key = layer.protocol == :arp ? (direction == :src ? :spa : :tpa) : direction
        layer.display(key)
      end
    end

    class Analysis
      # @rbs (?registry: Redhound::Registry, **untyped options) -> void
      def initialize(registry: Redhound::Registry.default, **options)
        @session = Redhound::Analysis::Session.new(registry: registry, stats: [], **options)
      end
      # @rbs (PacketView packet) -> void
      def update(packet) = @session.update(packet.raw_packet)
      # @rbs () -> void
      def close
        @session.finish(StringIO.new, StringIO.new)
      end
    end

    class FieldCatalog
      # @rbs () -> void
      def initialize
        @mutex = Mutex.new
        @fields = {} #: Hash[String, Hash[Symbol, untyped]]
        @protocols = Redhound::Registry.default.protocols.keys.map { |id| id == :ipv4 ? "ip" : id.to_s }
        Redhound::Registry.default.protocols.each do |id, klass|
          definitions = Array(klass.compiled_header&.definitions) #: Array[Redhound::FieldDefinition]
          definitions.each do |field|
            @fields[field.name] = {type: field.type, source: :dissect, protocol: id.to_s}.freeze
          end
        end
        @names = (@fields.keys + @protocols).sort.freeze
      end
      # @rbs () -> Array[String]
      def names = @mutex.synchronize { @names }
      # @rbs (String name) -> Hash[Symbol, untyped]?
      def lookup(name) = @mutex.synchronize { @fields[name] }
      # @rbs (String name) -> bool
      def protocol?(name) = @protocols.include?(name)
      # @rbs (PacketView packet) -> void
      def observe(packet)
        fields = packet.fields
        @mutex.synchronize do
          changed = false
          fields.each do |field|
            next if @fields.key?(field.name)
            @fields[field.name] = {type: field.type, source: :dissect, protocol: field.name.split(".").first}.freeze
            changed = true
          end
          @names = (@fields.keys + @protocols).sort.freeze if changed
        end
      end
    end
  end
end
