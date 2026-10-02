# frozen_string_literal: true
# rbs_inline: enabled

require_relative "dissector"

module Vanken
  module Gateway
    HierarchyRow = Data.define(
      :path, #: Array[Symbol]
      :packets, #: Integer
      :bytes #: Integer
    )
    ConversationRow = Data.define(
      :addr_a, #: String
      :port_a, #: Integer
      :addr_b, #: String
      :port_b, #: Integer
      :packets_ab, #: Integer
      :packets_ba, #: Integer
      :bytes_ab, #: Integer
      :bytes_ba, #: Integer
      :start_ns, #: Integer
      :end_ns, #: Integer
      :duration_ns #: Integer
    )
    EndpointRow = Data.define(
      :address, #: String
      :port, #: Integer
      :packets_tx, #: Integer
      :packets_rx, #: Integer
      :bytes_tx, #: Integer
      :bytes_rx #: Integer
    )
    StatisticsTable = Data.define(
      :kind, #: Symbol
      :type, #: Symbol?
      :rows, #: Array[HierarchyRow | ConversationRow | EndpointRow]
      :evicted #: Integer
    )

    # The upstream session and its private table schema stay inside the Gateway.
    class Statistics
      # @rbs (?specs: Array[String], ?registry: Redhound::Registry, **untyped options) -> void
      def initialize(specs: ["phs"], registry: Redhound::Registry.default, **options)
        @session = Redhound::Analysis::Session.new(stats: specs, registry: registry, **options)
      end

      # @rbs (PacketView packet) -> void
      def update(packet) = @session.update(packet.raw_packet)

      # @rbs () -> Array[StatisticsTable]
      def tables
        @session.statistics.map do |table|
          value = table.to_h
          rows = value[:rows].map do |row|
            fields = row.dup #: Hash[Symbol, untyped]
            fields[:path] = fields[:path].dup.freeze if fields[:path]
            fields.each_value { |item| item.freeze if item.is_a?(String) }
            case value[:kind]
            when :phs
              HierarchyRow.new(path: fields.fetch(:path), packets: fields.fetch(:packets), bytes: fields.fetch(:bytes))
            when :conv
              ConversationRow.new(addr_a: fields.fetch(:addr_a), port_a: fields.fetch(:port_a),
                addr_b: fields.fetch(:addr_b), port_b: fields.fetch(:port_b),
                packets_ab: fields.fetch(:packets_ab), packets_ba: fields.fetch(:packets_ba),
                bytes_ab: fields.fetch(:bytes_ab), bytes_ba: fields.fetch(:bytes_ba),
                start_ns: fields.fetch(:start_ns), end_ns: fields.fetch(:end_ns), duration_ns: fields.fetch(:duration_ns))
            when :endpoints
              EndpointRow.new(address: fields.fetch(:address), port: fields.fetch(:port),
                packets_tx: fields.fetch(:packets_tx), packets_rx: fields.fetch(:packets_rx),
                bytes_tx: fields.fetch(:bytes_tx), bytes_rx: fields.fetch(:bytes_rx))
            else raise Vanken::Error, "invalid upstream statistics table"
            end
          end
          StatisticsTable.new(kind: value[:kind], type: value[:type], rows: rows.freeze, evicted: table.evicted)
        end.freeze
      end

      # @rbs () -> void
      def close = @session.finish(StringIO.new, StringIO.new)
    end
  end
end
