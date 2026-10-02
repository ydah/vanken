# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Core
    class FrameView
      def initialize(document, number, packet: nil)
        @document, @number, @packet = document, number, packet
        @metadata = document.store.metadata(number)
      end
      def layer?(name) = !!@document.columns.layer?(@number, name)
      def field_type(name) = packet.field_type(name)
      def values(name)
        case name
        when "frame.number" then [@number]
        when "frame.len" then [@metadata[:original_length]]
        when "frame.cap_len" then [@metadata[:caplen]]
        when "frame.time_epoch" then [@metadata[:timestamp_ns] / 1e9]
        when "frame.time_relative" then [(@metadata[:timestamp_ns] - @document.store.metadata(1)[:timestamp_ns]) / 1e9]
        when "frame.time_delta" then [@number == 1 ? 0.0 : (@metadata[:timestamp_ns] - @document.store.metadata(@number - 1)[:timestamp_ns]) / 1e9]
        when "frame.time_delta_displayed" then [@document.time_value(@number, :delta_displayed)]
        when "frame.interface_name" then @metadata[:interface] ? [@metadata[:interface]["name"]] : []
        when "frame.direction" then @metadata[:direction] ? [@metadata[:direction].to_s] : []
        when "frame.marked" then [@document.marked.include?(@number)]
        when "frame.ignored" then [@document.ignored.include?(@number)]
        when "frame.protocols" then [column[:layers].join(":")]
        when "tcp.port", "udp.port", "tcp.srcport", "tcp.dstport", "udp.srcport", "udp.dstport"
          protocol = name.split(".").first
          return [] unless layer?(protocol)
          return [column[:src_port], column[:dst_port]].reject(&:negative?) if name.end_with?(".port")
          [column[name.end_with?("srcport") ? :src_port : :dst_port]].reject(&:negative?)
        when "tcp.stream" then annotation[:tcp_stream] >= 0 ? [annotation[:tcp_stream]] : []
        when "tcp.seq_relative" then annotation[:seq_rel] >= 0 ? [annotation[:seq_rel]] : []
        when "tcp.ack_relative" then annotation[:ack_rel] >= 0 ? [annotation[:ack_rel]] : []
        when "tcp.analysis.flags" then annotation[:analysis_flags].empty? ? [] : [true]
        when "expert.severity" then annotation[:expert_items].map { |item| item[:severity].to_s }
        when "expert.code" then annotation[:expert_items].map { |item| item[:code] }
        else
          if name.start_with?("tcp.analysis.")
            return [true] if annotation[:analysis_flags].include?(name.delete_prefix("tcp.analysis."))
            return Array(annotation[:extra][name]).compact
          end
          packet.values(name)
        end
      end
      private
      def column = @column ||= @document.columns[@number]
      def annotation = @annotation ||= @document.annotations[@number]
      def packet = @packet ||= @document.packet(@number)
    end
  end
end
