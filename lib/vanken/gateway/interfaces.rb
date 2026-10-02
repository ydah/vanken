# frozen_string_literal: true

require "redhound"
require "open3"

module Vanken
  module Gateway
    module Interfaces
      class NotFound < StandardError; end

      # @rbs () -> Array[Hash[Symbol, untyped]]
      def self.list
        result = Redhound::Capture.interfaces.map do |interface|
          {name: interface.name, index: interface.index, linktype: interface.linktype,
           snaplen: interface.snaplen, description: interface.description, mac: interface.mac,
           mtu: interface.mtu, up: interface.up?, running: interface.running?, loopback: interface.loopback?}
        end #: Array[Hash[Symbol, untyped]]
        if RUBY_PLATFORM.include?("linux")
          result << {name: "any", index: 0, linktype: 276, snaplen: 262_144,
                     description: "All interfaces", mac: nil, mtu: nil, up: true, running: true, loopback: false}
        end
        result
      end

      # @rbs (String name) -> Hash[Symbol, untyped]
      def self.find(name)
        list.find { |interface| interface[:name] == name } || raise(NotFound, "interface #{name.inspect} not found")
      end

      # @rbs () -> Hash[String, Integer]
      def self.traffic_counters
        if RUBY_PLATFORM.include?("linux")
          parse_linux_counters(File.read("/proc/net/dev"))
        elsif RUBY_PLATFORM.include?("darwin")
          output, _, status = Open3.capture3("/usr/sbin/netstat", "-ibn")
          status.success? ? parse_darwin_counters(output) : {}
        else
          {}
        end
      rescue SystemCallError, IOError
        {}
      end

      # @rbs (String text) -> Hash[String, Integer]
      def self.parse_linux_counters(text)
        result = {} #: Hash[String, Integer]
        text.each_line do |line|
          name, fields = line.split(":", 2)
          next unless name && fields
          values = fields.split
          next unless values.length >= 16 && values[0].match?(/\A\d+\z/) && values[8].match?(/\A\d+\z/)
          result[name.strip] = values[0].to_i + values[8].to_i
        end
        result
      end

      # @rbs (String text) -> Hash[String, Integer]
      def self.parse_darwin_counters(text)
        lines = text.lines
        header = lines.shift.to_s.split
        first, received, sent = header.index("Ipkts"), header.index("Ibytes"), header.index("Obytes")
        return {} unless first && received && sent
        result = {} #: Hash[String, Integer]
        lines.each do |line|
          fields = line.split
          next unless fields[2]&.start_with?("<Link#")
          counters = fields.last(header.length - first)
          incoming, outgoing = counters[received - first], counters[sent - first]
          next unless incoming&.match?(/\A\d+\z/) && outgoing&.match?(/\A\d+\z/)
          result[fields.first.delete_suffix("*")] = incoming.to_i + outgoing.to_i
        end
        result
      end

      # @rbs (?previous: Hash[Symbol, untyped]?, ?history: Hash[String, Array[Integer]], ?now: Integer | Float) -> Hash[Symbol, untyped]
      def self.sample_traffic(previous: nil, history: {}, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        counters = traffic_counters
        elapsed = previous ? now.to_f - previous[:time].to_f : 0.0
        rates = counters.to_h do |name, bytes|
          old = previous && previous[:counters][name]
          rate = old && elapsed.positive? ? [(bytes - old).fdiv(elapsed), 0].max.to_i : 0
          [name, rate]
        end
        samples = rates.to_h { |name, rate| [name, ((history[name] || []) + [rate]).last(60)] }
        {previous: {time: now, counters: counters}, rates: rates, history: samples}
      end
    end
  end
end
