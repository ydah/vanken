# frozen_string_literal: true

require "redhound"
require_relative "interfaces"
require_relative "capture_filter"

module Vanken
  module Gateway
    class LiveCapture
      class Error < StandardError
        attr_reader :code, :exit_code

        def initialize(message, code:, exit_code: 1)
          @code, @exit_code = code, exit_code
          super(message)
        end
      end

      attr_reader :backend

      def self.open(**options)
        interface = Interfaces.find(options.fetch(:interface))
        if options[:filter] && !options[:filter].empty?
          CaptureFilter.compile(options[:filter], linktype: interface[:linktype], snaplen: options.fetch(:snaplen, 262_144), live: RUBY_PLATFORM.include?("linux"))
        end
        new(Redhound::Capture.open(**options))
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

      def initialize(source)
        @source = source
        @backend = case source
                   when Redhound::Capture::Linux::TPacketV3 then :ring
                   when Redhound::Capture::Linux::PacketSocket then :socket
                   when Redhound::Capture::Bsd::BpfDevice then :bpf
                   else :unknown
                   end
      end

      def next_packet(timeout: 0.05) = @source.next_packet(timeout: timeout)
      def stopped? = @source.stopped?
      def stats = @source.stats.to_h
      def linktype = @source.linktype
      def interfaces
        @source.interfaces.map do |interface|
          {name: interface.name, linktype: interface.linktype, snaplen: interface.snaplen,
           description: interface.description, mac: interface.mac, mtu: interface.mtu}
        end
      end

      def stop = @source.stop
      def close = @source.close

      def self.version = Redhound::VERSION
    end
  end
end
