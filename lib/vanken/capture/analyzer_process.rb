# frozen_string_literal: true

require "rbconfig"
require_relative "analyzer_wire"

module Vanken
  module Capture
    class AnalyzerProcess
      attr_reader :pid
      def initialize(document, verify_checksums: false)
        @document, @verify_checksums = document, verify_checksums
      end
      def run
        unless Gem.win_platform?
          raise Vanken::Error, "packet analysis must run without root privileges" if Process.uid.zero? || Process.euid.zero?
        end
        child_in, @input = IO.pipe
        @output, child_out = IO.pipe
        [child_in, @input, @output, child_out].each(&:binmode)
        arguments = [RbConfig.ruby]
        arguments << "--yjit" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
        arguments << File.expand_path("analyzer_worker.rb", __dir__)
        @pid = Process.spawn(*arguments, in: child_in, out: child_out, close_others: true)
        child_in.close
        child_out.close
        request(command: :start, spool: @document.store.directory, verify_checksums: @verify_checksums, analysis_options: @document.analysis_options)
        number = 1
        loop do
          break if @document.closing?
          limit = @document.store.durable_count
          if number > limit
            break if @document.received? && number > @document.store.durable_count
            @document.wait_for_frames
            next
          end
          last = [number + 255, limit].min
          configuration = @document.analysis_configuration(number, last)
          batch = request(configuration.merge(command: :analyze, first: number, last: last, interfaces: @document.store.interfaces))
          raise Vanken::Error, "analysis response range mismatch" unless batch[:first] == number && batch[:last] == last
          @document.publish_analysis_batch(batch, self, configuration[:generation], context_token: configuration[:context_token])
          number = last + 1
        end
      rescue StandardError
        @document.cancel
        raise unless @document.closing?
      ensure
        child_in&.close unless child_in&.closed?
        child_out&.close unless child_out&.closed?
        begin
          shutdown
        ensure
          @document.analyzing_done
        end
      end
      def request(value)
        AnalyzerWire.write(@input, value)
        response = AnalyzerWire.read(@output, cancelled: -> { @document.closing? })
        raise Vanken::Error, response[:error] if response[:error]
        response
      end
      def shutdown
        begin
          AnalyzerWire.write(@input, {command: :stop}) if @pid && @input && !@input.closed?
        rescue IOError, SystemCallError
          nil
        ensure
          @input&.close unless @input&.closed?
          @output&.close unless @output&.closed?
        end
        return unless @pid
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        status = nil
        loop do
          if (result = Process.waitpid2(@pid, Process::WNOHANG))
            status = result.last
            break
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            Process.kill("KILL", @pid)
            status = Process.waitpid2(@pid).last
            break
          end
          sleep(0.005)
        end
        raise Vanken::Error, "analysis worker failed while stopping" unless status.success? || @document.closing? || $!
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end
end
