# frozen_string_literal: true

require_relative "capture_filter"
require_relative "../core/display_filter/parser"

module Vanken
  module Gateway
    class DisplayCaptureFilter
      Packet = Struct.new(:data, :original_length, :linktype, :meta)
      TUNNEL_PORTS = [4789, 8472, 6081].freeze
      attr_reader :expression

      def initialize(expression)
        @expression = convert(Core::DisplayFilter::Parser.new(expression).parse)
        @program = CaptureFilter.compile(@expression) if @expression
      rescue CaptureFilter::Error
        @expression = @program = nil
      end

      # nil requests the ordinary VDF evaluator; false is a definite non-match.
      def match(frame)
        return nil unless @program && eligible?(frame)
        @program.match?(Packet.new(frame.bytes, frame.original_length, frame.linktype, {}))
      end

      private

      def convert(node)
        case node.kind
        when :and, :or
          left, right = convert(node.left), convert(node.right)
          "(#{left}) #{node.kind} (#{right})" if left && right
        when :not
          child = convert(node.left)
          "not (#{child})" if child
        when :test
          field, predicate = node.left.value, node.right
          return {"ip" => "ip", "ipv6" => "ip6", "tcp" => "tcp", "udp" => "udp"}[field] unless predicate
          return nil unless %i[eq ne in].include?(predicate.operator)
          members = predicate.values.map { |member| term(field, member) }
          return nil if members.any?(&:nil?) || members.empty?
          result = members.map { |member| "(#{member})" }.join(" or ")
          predicate.operator == :ne ? "not (#{result})" : result
        end
      end

      def term(field, member)
        token = member.first
        if (port = /\A(tcp|udp)\.(port|srcport|dstport)\z/.match(field))
          return nil unless token.type == :integer && token.value.between?(0, 65_535)
          direction = {"srcport" => "src ", "dstport" => "dst "}.fetch(port[2], "")
          if member.last
            last = member.last
            return nil unless last.type == :integer && last.value.between?(token.value, 65_535)
            "#{port[1]} #{direction}portrange #{token.value}-#{last.value}"
          else
            "#{port[1]} #{direction}port #{token.value}"
          end
        elsif (address = /\A(ip|ipv6)\.(addr|src|dst)\z/.match(field))
          return nil unless token.type == :address && !member.last
          value = IPAddr.new(token.value)
          return nil unless value.ipv4? == (address[1] == "ip")
          direction = {"src" => "src ", "dst" => "dst "}.fetch(address[2], "")
          prefix = token.value.split("/", 2)[1]
          literal = prefix ? "net #{value}/#{prefix}" : "host #{value}"
          "#{address[1] == 'ip' ? 'ip' : 'ip6'} #{direction}#{literal}"
        end
      end

      def eligible?(frame)
        bytes = frame.bytes
        return false unless frame.linktype == 1 && frame.original_length == bytes.bytesize && bytes.bytesize >= 34
        type = bytes.unpack1("n", offset: 12)
        if type == 0x0800
          return false unless bytes.getbyte(14) == 0x45 && (bytes.unpack1("n", offset: 20) & 0x3fff).zero?
          length = bytes.unpack1("n", offset: 16)
          return false unless length >= 20 && length + 14 <= bytes.bytesize
          transport, finish, protocol = 34, length + 14, bytes.getbyte(23)
        elsif type == 0x86dd
          return false unless bytes.bytesize >= 54 && bytes.getbyte(14) >> 4 == 6
          length = bytes.unpack1("n", offset: 18)
          return false unless length.positive? && length + 54 <= bytes.bytesize
          transport, finish, protocol = 54, length + 54, bytes.getbyte(20)
        else
          return false
        end
        if protocol == 6
          return false unless finish - transport >= 20
          header = (bytes.getbyte(transport + 12) >> 4) * 4
          header >= 20 && transport + header <= finish
        elsif protocol == 17
          return false unless finish - transport >= 8
          ports = bytes.unpack("n2", offset: transport)
          length = bytes.unpack1("n", offset: transport + 4)
          (ports & TUNNEL_PORTS).empty? && length >= 8 && transport + length <= finish
        else
          false
        end
      end
    end
  end
end
