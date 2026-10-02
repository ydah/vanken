# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Core
    class FrameView
      # @rbs (App::Document document, Integer number, ?packet: Gateway::PacketView?, ?snapshot: Hash[Symbol, untyped]?) -> void
      def initialize(document, number, packet: nil, snapshot: nil)
        @document, @number, @packet = document, number, packet
        @snapshot = snapshot
        @metadata = document.store.metadata(number) #: frame_metadata
      end
      # @rbs (String name) -> bool
      def layer?(name) = @packet ? @packet.layer?(name) : !!@document.columns.layer?(@number, name)
      # @rbs (String name) -> Symbol?
      def field_type(name) = packet.field_type(name)
      # @rbs (String name) -> Array[untyped]
      def values(name)
        case name
        when "frame.number" then [@number]
        when "frame.len" then [@metadata[:original_length]]
        when "frame.cap_len" then [@metadata[:caplen]]
        when "frame.time_epoch" then [@metadata[:timestamp_ns] / 1e9]
        when "frame.time_relative" then [@document.time_value(@number, :relative, references: @snapshot&.fetch(:references))]
        when "frame.time_delta" then [@number == 1 ? 0.0 : (@metadata[:timestamp_ns] - @document.store.metadata(@number - 1)[:timestamp_ns]) / 1e9]
        when "frame.time_delta_displayed" then [displayed_delta]
        when "frame.interface_name" then @metadata[:interface] ? [@metadata[:interface]["name"]] : []
        when "frame.direction" then @metadata[:direction] ? [@metadata[:direction].to_s] : []
        when "frame.marked" then [(@snapshot ? @snapshot[:marked] : @document.marked).include?(@number)]
        when "frame.ignored" then [(@snapshot ? @snapshot[:ignored] : @document.ignored).include?(@number)]
        when "frame.protocols" then [column[:layers].join(":")]
        when "tcp.port", "udp.port", "tcp.srcport", "tcp.dstport", "udp.srcport", "udp.dstport"
          @packet ? @packet.values(name) : @document.columns.port_values(@number, name)
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
      # @rbs () -> column_values
      def column = @column ||= @packet ? @packet.columns : @document.columns[@number]
      # @rbs () -> annotation_values
      def annotation = @annotation ||= @packet ? @packet.annotations : @document.annotations[@number]
      # @rbs () -> Gateway::PacketView | Gateway::PacketSnapshot
      def packet = @packet ||= @document.packet_snapshot(@number) || @document.packet(@number)
      # @rbs () -> Float
      def displayed_delta
        return @document.time_value(@number, :delta_displayed) unless @snapshot

        previous = @document.displayed_predecessor(@number, @snapshot)
        previous > 0 ? (@metadata[:timestamp_ns] - @document.store.metadata(previous)[:timestamp_ns]) / 1e9 : 0.0
      end
    end
  end
end
