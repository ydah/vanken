# frozen_string_literal: true

require "redhound"
require_relative "interfaces"
require_relative "capture_filter"

module Vanken
  module Gateway
    class LiveCapture
      class Error < StandardError
        attr_reader :code #: String
        attr_reader :exit_code #: Integer

        # @rbs (String message, code: String, ?exit_code: Integer) -> void
        def initialize(message, code:, exit_code: 1)
          @code, @exit_code = code, exit_code
          super(message)
        end
      end

      attr_reader :backend #: Symbol

      # @rbs (interface: String, ?backend: Symbol | String, ?snaplen: Integer, ?promiscuous: bool, ?buffer_size: Integer?, ?direction: Symbol, ?filter: String?) -> LiveCapture
      def self.open(interface:, backend: :auto, snaplen: 262_144, promiscuous: true, buffer_size: nil, direction: :inout, filter: nil)
        metadata = Interfaces.find(interface)
        if filter && !filter.empty?
          CaptureFilter.compile(filter, linktype: metadata[:linktype], snaplen: snaplen, live: RUBY_PLATFORM.include?("linux"))
        end
        new(Redhound::Capture.open(interface: interface, backend: backend, snaplen: snaplen, promiscuous: promiscuous,
          buffer_size: buffer_size, direction: direction, filter: filter))
      rescue Interfaces::NotFound, Redhound::InterfaceNotFound => e
        raise Error.new(e.message, code: "interface_not_found")
      rescue CaptureFilter::Error, Redhound::FilterError => e
        raise Error.new(e.message, code: "invalid_filter", exit_code: 2)
      rescue Redhound::PermissionDenied, Errno::EACCES, Errno::EPERM => e
        raise Error.new(e.message, code: "permission_denied", exit_code: 3)
      rescue Redhound::UnsupportedPlatform => e
        raise Error.new(e.message, code: "unsupported_platform")
      rescue Redhound::CaptureError, NotImplementedError, ArgumentError => e
        raise Error.new(e.message, code: "backend_unavailable")
      end

      # @rbs (Redhound::Capture::Source source) -> void
      def initialize(source)
        @source = source
        @backend = case source
                   when Redhound::Capture::Linux::TPacketV3 then :ring
                   when Redhound::Capture::Linux::PacketSocket then :socket
                   when Redhound::Capture::Bsd::BpfDevice then :bpf
                   else :unknown
                   end
      end

      # @rbs (?timeout: Numeric?) -> Redhound::Packet?
      def next_packet(timeout: 0.05) = @source.next_packet(timeout: timeout)
      # @rbs () -> bool
      def stopped? = @source.stopped?
      # @rbs () -> Hash[Symbol, Integer]
      def stats = @source.stats.to_h
      # @rbs () -> Integer
      def linktype = @source.linktype
      # @rbs () -> Array[Hash[Symbol, untyped]]
      def interfaces
        @source.interfaces.map do |interface|
          {name: interface.name, linktype: interface.linktype, snaplen: interface.snaplen,
           description: interface.description, mac: interface.mac, mtu: interface.mtu}
        end
      end

      # @rbs () -> void
      def stop = @source.stop
      # @rbs () -> void
      def close = @source.close

      # @rbs () -> String
      def self.version = Redhound::VERSION
    end
  end
end
