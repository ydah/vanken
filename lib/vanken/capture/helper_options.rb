# frozen_string_literal: true

require "optparse"

module Vanken
  module Capture
    class HelperOptions
      attr_reader :command, :capture, :drop_to, :stats_interval, :flush_interval,
                  :stop_count, :stop_duration, :stop_bytes

      def self.parse(argv)
        new.parse(argv)
      end

      def initialize
        @command = :capture
        @capture = {interface: nil, filter: nil, snaplen: 262_144, promiscuous: true,
                    buffer_size: 4 * 1024 * 1024, direction: :inout, backend: :auto}
        @stats_interval = 1.0
        @flush_interval = 0.05
      end

      def parse(argv)
        modes = []
        parser = OptionParser.new do |opts|
          opts.on("-i", "--interface IF") { |v| @capture[:interface] = v }
          opts.on("-f", "--filter EXPR") { |v| @capture[:filter] = v }
          opts.on("--snaplen N", Integer) { |v| @capture[:snaplen] = bounded(v, 1..16_777_216, "snaplen") }
          opts.on("--no-promiscuous") { @capture[:promiscuous] = false }
          opts.on("--buffer-size N", Integer) { |v| @capture[:buffer_size] = bounded(v, 65_536..268_435_456, "buffer-size") }
          opts.on("--direction VALUE", %w[in out inout]) { |v| @capture[:direction] = v.to_sym }
          opts.on("--backend VALUE", %w[auto ring socket bpf]) { |v| @capture[:backend] = v.to_sym }
          opts.on("--drop-to UID:GID") do |v|
            raise ArgumentError, "drop-to must be a non-root UID:GID" unless v.match?(/\A[0-9]+:[0-9]+\z/)

            @drop_to = v.split(":").map { |id| bounded(Integer(id, 10), 1..4_294_967_294, "drop-to") }
          end
          opts.on("--stats-interval SEC", Float) { |v| @stats_interval = bounded(v, 0.01..60, "stats-interval") }
          opts.on("--flush-interval SEC", Float) { |v| @flush_interval = bounded(v, 0.001..1, "flush-interval") }
          opts.on("--stop-count N", Integer) { |v| @stop_count = bounded(v, 1..9_223_372_036_854_775_807, "stop-count") }
          opts.on("--stop-duration SEC", Float) { |v| @stop_duration = bounded(v, 0.001..31_536_000, "stop-duration") }
          opts.on("--stop-bytes N", Integer) { |v| @stop_bytes = bounded(v, 1..9_223_372_036_854_775_807, "stop-bytes") }
          opts.on("--list-interfaces") { modes << :list_interfaces }
          opts.on("--check") { modes << :check }
          opts.on("--version") { modes << :version }
          opts.on("-h", "--help") { modes << :help }
        end
        # OptionParser accepts long-option abbreviations by default; privileged inputs must be exact.
        known = %w[--interface --filter --snaplen --no-promiscuous --buffer-size --direction --backend --drop-to --stats-interval --flush-interval --stop-count --stop-duration --stop-bytes --list-interfaces --check --version --help]
        argv.each do |arg|
          raise ArgumentError, "unknown option: #{arg}" if arg.start_with?("--") && !known.include?(arg.split("=", 2).first)
        end
        remaining = parser.parse(argv.dup)
        raise ArgumentError, "unexpected arguments: #{remaining.join(' ')}" unless remaining.empty?
        raise ArgumentError, "conflicting commands" if modes.length > 1

        @command = modes.first || :capture
        raise ArgumentError, "interface is required" if @command == :capture && @capture[:interface].to_s.empty?

        self
      rescue OptionParser::ParseError => e
        raise ArgumentError, e.message
      end

      private

      def bounded(value, range, name)
        raise ArgumentError, "#{name} must be in #{range}" unless range.cover?(value)

        value
      end
    end
  end
end
