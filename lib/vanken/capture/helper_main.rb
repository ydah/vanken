# frozen_string_literal: true

require "etc"
require_relative "../version"
require_relative "helper_options"
require_relative "control_protocol"
require_relative "privileges"
require_relative "../gateway/live_capture"
require_relative "../gateway/file_writer"

module Vanken
  module Capture
    class HelperMain
      def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV)
        @stdin, @stdout, @env = stdin, stdout, env
        @control = ControlProtocol.new(stderr)
      end

      def run(argv)
        @control.write(:hello, pid: Process.pid, vanken: VERSION, redhound: Gateway::LiveCapture.version, ruby: RUBY_VERSION)
        options = HelperOptions.parse(argv)
        case options.command
        when :list_interfaces then @stdout.puts(JSON.generate(Gateway::Interfaces.list)); return 0
        when :check then return check(options)
        when :version then @stdout.puts("Vanken #{VERSION}"); return 0
        when :help then @stdout.puts("vanken-capture -i INTERFACE [--filter EXPR] [--snaplen N] [--no-promiscuous]\n  [--buffer-size BYTES] [--direction in|out|inout] [--backend auto|ring|socket|bpf]\n  [--drop-to UID:GID] [--stats-interval SEC] [--flush-interval SEC]\n  [--stop-count N] [--stop-duration SEC] [--stop-bytes BYTES]\n  --list-interfaces | --check [--interface IF] | --version"); return 0
        end

        capture(options)
      rescue ArgumentError => e
        failure("internal", e.message, 2)
      rescue Gateway::Interfaces::NotFound => e
        failure("interface_not_found", e.message, 2)
      rescue Gateway::LiveCapture::Error => e
        failure(e.code, e.message, e.exit_code)
      rescue Privileges::Error, Errno::EPERM, Errno::EACCES => e
        failure("permission_denied", e.message, 3)
      rescue Vanken::FileError, IOError, Errno::EPIPE, Errno::ENOSPC => e
        failure("write_failed", e.message, 1)
      rescue StandardError => e
        failure("internal", e.message, 1)
      end

      private

      def capture(options)
        drop_to = options.drop_to || drop_target
        if Process.euid.zero? && !drop_to
          raise Privileges::Error, "privileged capture requires --drop-to UID:GID or an invoking user identity"
        end
        Gateway::Interfaces.find(options.capture[:interface])
        source = Gateway::LiveCapture.open(**options.capture)
        dropped = drop_to ? Privileges.drop!(*drop_to) : false
        @stdout.binmode
        writer = Gateway::FileWriter.open(@stdout, format: :pcapng, linktype: source.linktype, snaplen: options.capture[:snaplen])
        @stop_reason = nil
        previous_traps = %w[TERM INT].to_h { |signal| [signal, Signal.trap(signal) { @stop_reason ||= "signal" }] }
        monitor = Thread.new do
          Thread.current.report_on_exception = false
          @stdin.read(1) until @stdin.eof?
          @stop_reason ||= "stdin_closed"
        rescue IOError, SystemCallError
          @stop_reason ||= "stdin_closed"
        end
        @control.write(:started, interface: options.capture[:interface], linktype: source.linktype,
                       snaplen: options.capture[:snaplen], backend: source.backend, filter: options.capture[:filter], privileges_dropped: dropped)
        started_at = flushed_at = stats_at = monotonic
        captured = 0
        until @stop_reason || source.stopped?
          packet = source.next_packet(timeout: 0.05)
          if packet
            writer << packet
            captured += 1
          end
          now = monotonic
          @stop_reason ||= "count_limit" if options.stop_count && captured >= options.stop_count
          @stop_reason ||= "duration_limit" if options.stop_duration && now - started_at >= options.stop_duration
          @stop_reason ||= "bytes_limit" if options.stop_bytes && writer.bytes_written >= options.stop_bytes
          if now - flushed_at >= options.flush_interval
            writer.flush
            flushed_at = now
          end
          if now - stats_at >= options.stats_interval
            @control.write(:stats, **source.stats, ts: Time.now.to_f)
            stats_at = now
          end
        end
        stats = source.stats
        writer.write_stats(stats)
        writer.close
        writer = nil
        @control.write(:stopped, reason: @stop_reason || "source_closed", stats: stats)
        0
      ensure
        monitor&.kill
        monitor&.join
        previous_traps&.each { |signal, handler| Signal.trap(signal, handler) }
        begin
          writer&.close
        ensure
          source&.close
        end
      end

      def check(options)
        interface = options.capture[:interface] || Gateway::Interfaces.list.find { |entry| entry[:up] }&.fetch(:name)
        raise Gateway::Interfaces::NotFound, "no capture interfaces found" unless interface

        source = Gateway::LiveCapture.open(**options.capture.merge(interface: interface))
        @stdout.puts(JSON.generate(direct: true, interface: interface, backend: source.backend, platform: RUBY_PLATFORM, uid: Process.uid))
        0
      rescue Gateway::LiveCapture::Error => e
        @stdout.puts(JSON.generate(direct: false, interface: interface, platform: RUBY_PLATFORM, uid: Process.uid, code: e.code, message: e.message))
        e.exit_code
      ensure
        source&.close
      end

      def drop_target
        return unless Process.euid.zero?
        return [Process.uid, Process.gid] unless Process.uid.zero?

        if @env["SUDO_UID"] && @env["SUDO_GID"]
          uid, gid = Integer(@env["SUDO_UID"], 10), Integer(@env["SUDO_GID"], 10)
        elsif @env["PKEXEC_UID"]
          uid = Integer(@env["PKEXEC_UID"], 10)
          gid = Etc.getpwuid(uid).gid
        end
        [uid, gid] if uid&.positive? && gid&.positive?
      rescue ArgumentError
        nil
      end

      def failure(code, message, exit_code)
        @control.write(:error, code: code, message: message, fatal: true)
        exit_code
      rescue IOError, SystemCallError
        exit_code
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
