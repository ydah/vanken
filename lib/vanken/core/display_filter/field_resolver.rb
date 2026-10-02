# frozen_string_literal: true

module Vanken
  module Core
    module DisplayFilter
      Reference = Data.define(:name, :type, :source, :protocol, :known)

      class FieldResolver
        PROTOCOLS = %w[eth vlan arp ip ipv6 icmp icmpv6 igmp tcp udp gre vxlan dns dhcp ntp http tls data].freeze
        FRAME_FIELDS = {
          "frame.number" => :integer, "frame.len" => :integer, "frame.cap_len" => :integer,
          "frame.time_epoch" => :float, "frame.time_relative" => :float, "frame.time_delta" => :float,
          "frame.time_delta_displayed" => :float, "frame.interface_name" => :string,
          "frame.direction" => :string, "frame.marked" => :boolean, "frame.ignored" => :boolean
        }.freeze
        VIRTUAL_FIELDS = {
          "frame.protocols" => :string, "ip.addr" => :address, "ipv6.addr" => :address,
          "eth.addr" => :mac, "tcp.port" => :integer, "udp.port" => :integer,
          "tcp.stream" => :integer, "expert.severity" => :severity, "expert.code" => :string,
          **%w[syn ack fin rst psh urg].to_h { |flag| ["tcp.flags.#{flag}", :boolean] }
        }.freeze

        def initialize(catalog = nil)
          @catalog = catalog
        end

        def resolve(name)
          entry = @catalog&.lookup(name)
          type = FRAME_FIELDS[name] || VIRTUAL_FIELDS[name] || metadata(entry, :type)
          type = :boolean if name.start_with?("tcp.analysis.")
          protocol = !name.include?(".") && (PROTOCOLS.include?(name) || @catalog&.protocol?(name))
          source = if FRAME_FIELDS.key?(name)
            :frame
          elsif name == "tcp.stream" || name.start_with?("tcp.analysis.", "expert.")
            :annotation
          elsif protocol || %w[tcp.port udp.port].include?(name)
            :column
          else
            metadata(entry, :source) || :dissect
          end
          Reference.new(name, normalize_type(type), source.to_sym, !!protocol, !!(type || entry || protocol))
        end

        def normalize_type(type)
          return nil unless type

          name = type.to_s.downcase
          return :integer if /\A(?:u?int\d*|integer|bitfield|bit_field|bits)\z/.match?(name)
          return :float if %w[float double time timestamp number].include?(name)
          return :boolean if %w[boolean bool].include?(name)
          return :address if %w[ipv4 ipv6 ipaddr address].include?(name)
          return :mac if %w[mac macaddr mac_address].include?(name)
          return :bytes if %w[bytes byte_array raw binary].include?(name)
          return :string if %w[string str text].include?(name)
          return :severity if name == "severity"

          nil
        end

        private

        def metadata(entry, key)
          return nil unless entry
          return entry[key] || entry[key.to_s] if entry.is_a?(Hash)
          return entry.public_send(key) if entry.respond_to?(key)

          nil
        end
      end
    end
  end
end
