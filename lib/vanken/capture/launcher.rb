# frozen_string_literal: true

require "json"
require "rbconfig"

module Vanken
  module Capture
    class Launcher
      class Unavailable < StandardError; end
      WRAPPER = "/usr/local/libexec/vanken/vanken-capture"
      SAFE_ENV = %w[DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY LANG LC_ALL TERM].freeze

      class Handle
        attr_reader :pid, :stdin, :stdout, :stderr, :status

        def initialize(pid, stdin, stdout, stderr)
          @pid, @stdin, @stdout, @stderr = pid, stdin, stdout, stderr
          @reap_lock = Mutex.new
        end

        def wait(timeout: nil)
          deadline = timeout && (monotonic + timeout)
          loop do
            @reap_lock.synchronize do
              return @status if @reaped
              result = Process.waitpid2(@pid, Process::WNOHANG)
              @reaped, @status = true, result.last if result
              return @status if @reaped
            rescue Errno::ECHILD
              @reaped = true
              return @status
            end
            return if deadline && monotonic >= deadline

            sleep 0.01
          end
        end

        def stop(timeout: 3)
          @stdin.close unless @stdin.closed?
          signal("TERM") unless @reaped
          return @status if wait(timeout: timeout)

          signal("KILL") unless @reaped
          wait
        end

        def close
          stop
          [@stdout, @stderr].each { |io| io.close unless io.closed? }
        end

        private

        def signal(signal)
          @reap_lock.synchronize do
            return if @reaped

            result = Process.waitpid2(@pid, Process::WNOHANG)
            if result
              @reaped, @status = true, result.last
            else
              Process.kill(signal, -@pid)
            end
          end
        rescue Errno::ECHILD
          @reaped = true
        rescue Errno::ESRCH
          nil
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def initialize(strategy: :auto, wrapper: WRAPPER, direct_command: nil, askpass: nil, env: ENV)
        @strategy, @wrapper, @askpass, @env = strategy.to_sym, wrapper, askpass, env
        lib = File.expand_path("../..", __dir__)
        helper = File.expand_path("../../../exe/vanken-capture", __dir__)
        dependency_paths = Gem.loaded_specs.fetch("redhound", nil)&.full_require_paths || []
        @direct_command = direct_command || [RbConfig.ruby, "-I", ([lib] + dependency_paths).join(File::PATH_SEPARATOR), helper]
      end

      def launch(options = [], strategy: @strategy)
        args = options.is_a?(Array) ? options : capture_argv(options.respond_to?(:capture) ? options.capture : options)
        strategy = strategy.to_sym
        strategy = automatic_strategy(args) if strategy == :auto
        command, extra_env = command_for(strategy, args)
        spawn(command, extra_env)
      rescue SystemCallError => e
        raise Unavailable, "cannot launch capture helper: #{e.message}"
      end

      def command_for(strategy, args)
        return [@direct_command + args, {}] if strategy == :direct
        raise Unavailable, "use direct capture or install the root-owned capture helper; developer sudo is disabled" unless %i[pkexec sudo].include?(strategy)

        trusted_path!(@wrapper)
        raise Unavailable, "capture must be launched by an unprivileged user" if Process.uid.zero? || Process.gid.zero?

        args = args + ["--drop-to", "#{Process.uid}:#{Process.gid}"]
        if strategy == :pkexec
          executable = executable("pkexec") || raise(Unavailable, "pkexec is unavailable")
          [[executable, @wrapper] + args, {}]
        else
          executable = executable("sudo") || raise(Unavailable, "sudo is unavailable")
          trusted_path!(@askpass) if @askpass
          [[executable, @askpass ? "-A" : "-n", "--", @wrapper] + args,
           @askpass ? {"SUDO_ASKPASS" => @askpass} : {}]
        end
      end

      def self.trusted_path?(path)
        return false unless path && path.start_with?("/") && File.realpath(path) == path && File.file?(path) && File.executable?(path)

        current = path
        loop do
          stat = File.stat(current)
          return false unless stat.uid.zero? && (stat.mode & 0o022).zero?
          return true if current == "/"

          current = File.dirname(current)
        end
      rescue SystemCallError
        false
      end

      private

      def spawn(command, extra_env = {})
        input_read, input_write = IO.pipe
        output_read, output_write = IO.pipe
        error_read, error_write = IO.pipe
        env = @env.to_h.slice(*SAFE_ENV).merge("PATH" => "/usr/bin:/bin:/usr/sbin:/sbin").merge(extra_env)
        pid = Process.spawn(env, [command.first, command.first], *command.drop(1),
                            in: input_read, out: output_write, err: error_write, unsetenv_others: true, close_others: true, pgroup: true)
        handle = Handle.new(pid, input_write, output_read, error_read)
      ensure
        [input_write, output_read, error_read].compact.each { |io| io.close unless io.closed? } unless handle
        [input_read, output_write, error_write].compact.each { |io| io.close unless io.closed? }
      end

      def automatic_strategy(args)
        interface_index = args.index("--interface") || args.index("-i")
        check_args = ["--check"]
        check_args += ["--interface", args.fetch(interface_index + 1)] if interface_index
        handle = spawn(@direct_command + check_args)
        if handle.wait(timeout: 3)
          diagnostic = JSON.parse(handle.stdout.read(65_537)) rescue {}
          return :direct if diagnostic["direct"] == true
        end
        trusted_path!(@wrapper)
        if RUBY_PLATFORM.include?("linux") && (@env["DISPLAY"] || @env["WAYLAND_DISPLAY"]) && executable("pkexec")
          :pkexec
        elsif executable("sudo")
          :sudo
        else
          raise Unavailable, "capture permission is unavailable; install the root-owned capture helper"
        end
      ensure
        handle&.close
      end

      def trusted_path!(path)
        raise Unavailable, "capture helper must be executable in a root-owned directory without group or other write access" unless self.class.trusted_path?(path)
      end

      def executable(name)
        %w[/usr/bin /bin].map { |directory| File.join(directory, name) }.find { |path| File.executable?(path) }
      end

      def capture_argv(options)
        options.flat_map do |key, value|
          next [] if value.nil?
          next value ? [] : ["--no-promiscuous"] if key.to_sym == :promiscuous

          ["--#{key.to_s.tr('_', '-')}", value.to_s]
        end
      end
    end
  end
end
