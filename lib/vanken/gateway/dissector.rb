# frozen_string_literal: true
# rbs_inline: enabled

require "redhound"
require "stringio"

module Vanken
  module Gateway
    PROTOCOLS = {"ip" => :ipv4}.freeze
    module Severity
      def self.normalize(value) = value == :warn ? :warning : value
      def self.rank(value) = {nil => 0, note: 1, warning: 2, warn: 2, error: 3}.fetch(value, 0)
    end

    class Dissector
      attr_reader :registry
      def initialize(verify_checksums: false, decode_as: [], plugins: [])
        @registry = Redhound::Registry.default.copy
        plugins.each { |path| load File.expand_path(path) }
        decode_as.each { |rule| @registry.decode_as(rule) }
        @engine = Redhound::Engine.new(registry: @registry, verify_checksums: verify_checksums)
      end
      def dissect(frame)
        packet = self.class.packet(frame)
        packet.engine = @engine
        PacketView.new(packet, @registry)
      rescue Redhound::Error, ArgumentError => error
        raise Vanken::FileError, error.message
      end
      def self.packet(frame, interfaces: {})
        interface = frame.interface && interfaces.fetch(frame.interface) do
          values = frame.interface.transform_keys(&:to_sym).select { |key, _| %i[name index linktype snaplen flags mtu mac description filter meta].include?(key) }
          interfaces[frame.interface] = Redhound::Capture::Interface.new(**values)
        end
        Redhound.dissect(frame.bytes, linktype: frame.linktype, timestamp_ns: frame.timestamp_ns,
          original_length: frame.original_length, interface: interface, direction: frame.direction, number: frame.number)
      end
    end

    class PacketView
      attr_reader :raw_packet
      def initialize(packet, registry) = (@raw_packet = packet; @registry = registry)
      def values(name)
        names = case name
        when "ip.addr" then %w[ip.src ip.dst]
        when "ipv6.addr" then %w[ipv6.src ipv6.dst]
        when "eth.addr" then %w[eth.src eth.dst]
        when "tcp.port" then %w[tcp.srcport tcp.dstport]
        when "udp.port" then %w[udp.srcport udp.dstport]
        else [name]
        end
        if name.start_with?("tcp.flags.")
          bit = {"fin" => 1, "syn" => 2, "rst" => 4, "psh" => 8, "ack" => 16, "urg" => 32}[name.split(".").last]
          return @raw_packet.field_values("tcp.flags").any? { |flags| flags & bit != 0 } ? [true] : [] if bit
        end
        names.flat_map { |field| @raw_packet.field_values(field) }.compact
      end
      def layer?(name) = @raw_packet.layers.any? { |layer| layer.protocol == PROTOCOLS.fetch(name, name.to_sym) }
      def fields = @raw_packet.layers.flat_map(&:fields)
      def field_type(name) = fields.find { |field| field.name == name }&.type
      def layers = @raw_packet.layers
      def bytes = @raw_packet.data
      def to_h = @raw_packet.to_h
      def diagnostics
        layers.flat_map do |layer|
          layer.diagnostics.map { |item| {severity: Severity.normalize(item.severity), code: item.code.to_s,
                                         protocol: layer.protocol.to_s, message: safe_text(item.message)} }
        end
      end
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
         layers: relevant.map { |layer| layer.protocol == :ipv4 ? "ip" : layer.protocol.to_s }.uniq}
      end
      def info
        safe_text(@raw_packet.summary)
      end
      def annotations
        extra = fields.select { |field| field.name.start_with?("tcp.analysis.", "tcp.reassembled", "ip.reassembled") }.to_h { |field| [field.name, field.value] }
        {tcp_stream: values("tcp.stream").first || -1, seq_rel: values("tcp.seq_relative").first || -1,
         ack_rel: values("tcp.ack_relative").first || -1,
         analysis_flags: Core::AnnotationStore::FLAGS.select { |flag| values("tcp.analysis.#{flag}").any? },
         expert_max: diagnostics.map { |item| Severity.rank(item[:severity]) }.max || 0,
         expert_items: diagnostics, extra: extra}
      end
      def reassembled? = @raw_packet.meta.key?(:reassembled_packet) || fields.any? { |field| field.name == "tcp.reassembled_from" }

      private
      def safe_text(value) = value.to_s.b.gsub(/[^\x20-\x7e]/n) { |byte| format("\\x%02x", byte.getbyte(0)) }
      def address_text(layer, direction)
        return "" unless layer
        key = layer.protocol == :arp ? (direction == :src ? :spa : :tpa) : direction
        layer.display(key)
      end
    end

    class Analysis
      def initialize(registry: Redhound::Registry.default, **options)
        @session = Redhound::Analysis::Session.new(registry: registry, stats: [], **options)
      end
      def update(packet) = @session.update(packet.raw_packet)
      def close
        @session.finish(StringIO.new, StringIO.new)
      end
    end

    class FieldCatalog
      attr_reader :names
      def initialize
        @fields = {}
        @protocols = Redhound::Registry.default.protocols.keys.map { |id| id == :ipv4 ? "ip" : id.to_s }
        Redhound::Registry.default.protocols.each do |id, klass|
          Array(klass.compiled_header&.definitions).each do |field|
            @fields[field.name] = {type: field.type, source: :dissect, protocol: id.to_s}
          end
        end
        @names = (@fields.keys + @protocols).sort
      end
      def lookup(name) = @fields[name]
      def protocol?(name) = @protocols.include?(name)
      def observe(packet)
        packet.fields.each { |field| @fields[field.name] ||= {type: field.type, source: :dissect, protocol: field.name.split(".").first} }
        @names = (@fields.keys + @protocols).sort
      end
    end
  end
end
