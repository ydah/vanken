# frozen_string_literal: true
# rbs_inline: enabled

require "json"

module Vanken
  module Gateway
    class DetailBuilder
      def build(packet, annotations: nil)
        raw = packet.raw_packet
        frame = node("frame", "Frame #{raw.number}: #{raw.original_length} bytes on wire, #{raw.caplen} captured", offset: 0, length: raw.caplen)
        nodes = packet.layers.each_with_index.map do |layer, index|
          prefix = packet.layers.count { |item| item.protocol == layer.protocol } > 1 ? "#{layer.protocol}[#{index}]" : layer.protocol.to_s
          klass = Redhound::Registry.default.protocols[layer.protocol]
          children = layer.fields.map do |field|
            value = field.value
            literal = value.is_a?(String) && !%i[ipv4 ipv6 mac].include?(field.type) ? JSON.generate(value.encode("UTF-8", invalid: :replace, undef: :replace)) : value.to_s
            node("#{prefix}/#{field.name}", "#{field.name.split('.').last.tr('_', ' ').capitalize}: #{field.display}",
              field: field.name, offset: field.length.positive? ? field.offset : nil, length: field.length,
              source: packet.reassembled? && %i[http dns tls].include?(layer.protocol) ? :reassembled : :frame,
              filter: "#{field.name} == #{literal}")
          end
          layer.diagnostics.each_with_index do |item, position|
            children << node("#{prefix}/expert/#{position}", "[#{Severity.normalize(item.severity)}: #{item.code}] #{escape(item.message)}", severity: Severity.normalize(item.severity))
          end
          node(prefix, klass&.protocol_name || layer.protocol.to_s.upcase, offset: layer.offset,
            length: layer.payload_end - layer.offset, children: children)
        end
        if annotations
          annotations[:extra].each do |field, value|
            next if packet.values(field).any?
            nodes << node("annotation/#{field}", "[#{field}: #{escape(value)}]", field: field, filter: "#{field} == #{value}")
          end
        end
        [frame, *nodes]
      end

      private
      def escape(value) = value.to_s.b.gsub(/[^\x20-\x7e]/n) { |byte| format("\\x%02x", byte.getbyte(0)) }
      def node(id, label, field: nil, offset: nil, length: 0, source: :frame, severity: nil, filter: nil, children: [])
        Core::DetailNode.new(id: id, label: label, field: field, offset: offset, length: length, source: source, severity: severity, filter: filter, children: children)
      end
    end
  end
end
