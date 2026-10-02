# frozen_string_literal: true
# rbs_inline: enabled

require "ipaddr"
require "resolv"
require "timeout"

module Vanken
  module Gateway
    # Reverse DNS never runs on the requesting thread. Callbacks run on the
    # worker; UI callers must post their publication to the UI executor.
    class Resolver
      NEGATIVE_TTL = 30.0

      # @rbs @timeout: Float
      # @rbs @limit: Integer
      # @rbs @resolver: untyped
      # @rbs @queue: SizedQueue[String?]
      # @rbs @cache: Hash[String, [String?, Float?]]
      # @rbs @pending: Hash[String, Array[^(String) -> void]]
      # @rbs @mutex: Mutex
      # @rbs @closed: bool
      # @rbs @worker: Thread

      # @rbs (?timeout: Integer | Float, ?limit: Integer, ?resolver: untyped) -> void
      def initialize(timeout: 1.0, limit: 256, resolver: nil)
        unless timeout.is_a?(Numeric) && timeout.to_f.finite? && timeout.positive?
          raise ArgumentError, "timeout must be finite and positive"
        end
        raise ArgumentError, "limit must be a positive integer" unless limit.is_a?(Integer) && limit.positive?
        @timeout, @limit = timeout.to_f, limit
        @resolver = resolver || Resolv::DNS.new
        @resolver.timeouts = [@timeout] if @resolver.respond_to?(:timeouts=)
        @queue = SizedQueue.new(@limit) #: SizedQueue[String?]
        @cache = {} #: Hash[String, [String?, Float?]]
        @pending = {} #: Hash[String, Array[^(String) -> void]]
        @mutex = Mutex.new
        @closed = false
        @worker = Thread.new { work }
        @worker.report_on_exception = false
      end

      # @rbs (String address) ?{ (String) -> void } -> String
      def request(address, &callback)
        key = numeric_address(address)
        return address unless key
        @mutex.synchronize do
          return address if @closed
          entry = @cache.delete(key)
          if entry && (!entry[1] || entry[1] > now)
            @cache[key] = entry
            return entry[0] || address
          end
          if (waiting = @pending[key])
            waiting << callback if callback
          else
            begin
              @queue.push(key, true)
              @pending[key] = callback ? [callback] : []
            rescue ThreadError
              # A future viewport request may retry after capacity is available.
            end
          end
          address
        end
      end

      # @rbs () -> void
      def close
        @mutex.synchronize do
          return if @closed
          @closed = true
          @pending.clear
          @queue.clear
          @queue << nil
        end
        @worker.join(@timeout + 0.1) unless Thread.current == @worker
        nil
      end

      private

      # @rbs (String address) -> String?
      def numeric_address(address)
        return nil if address.include?("/")
        IPAddr.new(address).to_s
      rescue IPAddr::Error
        nil
      end

      # @rbs () -> Float
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # @rbs (String address) -> String?
      def lookup(address)
        name = Timeout.timeout(@timeout) { @resolver.getname(address) }
        name.to_s.dup.freeze unless name.nil? || name.to_s.empty?
      rescue StandardError
        nil
      end

      # @rbs () -> void
      def work
        while (address = @queue.pop)
          name = lookup(address)
          callbacks = @mutex.synchronize do
            return if @closed
            @cache[address] = [name, name ? nil : now + NEGATIVE_TTL]
            @cache.shift while @cache.size > @limit
            @pending.delete(address) || []
          end
          next unless name
          callbacks.each do |callback|
            break if @mutex.synchronize { @closed }
            begin
              callback.call(name)
            rescue StandardError
              # One consumer must not prevent other consumers or DNS requests.
            end
          end
        end
      ensure
        begin
          @resolver.close if @resolver.respond_to?(:close)
        rescue StandardError
          nil
        end
      end
    end
  end
end
