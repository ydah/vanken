# frozen_string_literal: true

require "redhound"

module Vanken
  module Gateway
    module Interfaces
      class NotFound < StandardError; end

      def self.list
        result = Redhound::Capture.interfaces.map do |interface|
          {name: interface.name, index: interface.index, linktype: interface.linktype,
           snaplen: interface.snaplen, description: interface.description, mac: interface.mac,
           mtu: interface.mtu, up: interface.up?, running: interface.running?, loopback: interface.loopback?}
        end
        if RUBY_PLATFORM.include?("linux")
          result << {name: "any", index: 0, linktype: 276, snaplen: 262_144,
                     description: "All interfaces", mac: nil, mtu: nil, up: true, running: true, loopback: false}
        end
        result
      end

      def self.find(name)
        list.find { |interface| interface[:name] == name } || raise(NotFound, "interface #{name.inspect} not found")
      end
    end
  end
end
