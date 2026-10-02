# frozen_string_literal: true
# rbs_inline: enabled

require "json"

module Vanken
  module Gateway
    class DetailBuilder
      # @rbs (PacketView packet, ?annotations: Core::annotation_values?) -> Array[Core::DetailNode]
      def build(packet, annotations: nil)
        raw = packet.raw_packet
        frame = node("frame", "Frame #{raw.number}: #{raw.original_length} bytes on wire, #{raw.caplen} captured", offset: 0, length: raw.caplen)
        nodes = packet.layers.each_with_index.map do |layer, index|
          prefix = packet.layers.count { |item| item.protocol == layer.protocol } > 1 ? "#{layer.protocol}[#{index}]" : layer.protocol.to_s
          klass = packet.registry.protocols[layer.protocol]
          source = packet.layer_source(layer)
          children = layer.fields.map do |field|
            value = field.value
            node("#{prefix}/#{field.name}", "#{field.name.split('.').last.tr('_', ' ').capitalize}: #{field.display}",
              field: field.name, offset: field.length.positive? ? field.offset : nil, length: field.length,
              source: source,
              filter: "#{field.name} == #{literal(value, field.type)}")
          end
          layer.diagnostics.each_with_index do |item, position|
            children << node("#{prefix}/expert/#{position}", "[#{Severity.normalize(item.severity)}: #{item.code}] #{escape(item.message)}", source: source, severity: Severity.normalize(item.severity))
          end
          node(prefix, klass&.protocol_name || layer.protocol.to_s.upcase, offset: layer.offset,
            length: layer.payload_end - layer.offset, source: source, children: children)
        end
        if annotations
          annotations[:extra].each do |field, value|
            next if packet.values(field).any?
            nodes << node("annotation/#{field}", "[#{field}: #{escape(value)}]", field: field, filter: "#{field} == #{literal(value)}")
          end
        end
        [frame, *nodes]
      end

      private
      # @rbs (untyped value, ?Symbol? type) -> String
      def literal(value, type = nil)
        return value.to_s if %i[ipv4 ipv6 mac].include?(type) || !value.is_a?(String)
        return "0x#{value.unpack1('H*')}" if type == :bytes && !value.empty?

        escaped = value.b.bytes.map do |byte|
          case byte
          when 34 then '\\"'
          when 92 then "\\\\"
          when 32..126 then byte.chr
          else format("\\x%02x", byte)
          end
        end.join
        "\"#{escaped}\""
      end
      # @rbs (untyped value) -> String
      def escape(value) = value.to_s.b.gsub(/[^\x20-\x7e]/n) { |byte| format("\\x%02x", byte.getbyte(0)) }
      # @rbs (String id, String label, ?field: String?, ?offset: Integer?, ?length: Integer, ?source: Symbol, ?severity: Symbol?, ?filter: String?, ?children: Array[Core::DetailNode]) -> Core::DetailNode
      def node(id, label, field: nil, offset: nil, length: 0, source: :frame, severity: nil, filter: nil, children: [])
        Core::DetailNode.new(id: id, label: label, field: field, offset: offset, length: length, source: source, severity: severity, filter: filter, children: children)
      end
    end
  end
end
