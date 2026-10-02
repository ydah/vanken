# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "vanken/gateway/resolver"

RSpec.describe Vanken::Gateway::Resolver do
  class ControlledReverseLookup
    attr_accessor :timeouts
    attr_reader :calls, :answers, :closed

    def initialize
      @calls = Queue.new
      @answers = Queue.new
      @closed = false
    end

    def getname(address)
      @calls << [address, Thread.current]
      answer = @answers.pop
      raise answer if answer.is_a?(Exception)
      answer
    end

    def close = @closed = true
  end

  def await_result(queue) = Timeout.timeout(1) { queue.pop }

  def resolver_for(driver, **options)
    resolver = described_class.new(resolver: driver, **options)
    (@resolvers ||= []) << resolver
    resolver
  end

  after { @resolvers&.each(&:close) }

  it "returns immediately while reverse lookup runs on its dedicated worker" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver, timeout: 0.5)
    resolved = Queue.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(resolver.request("192.0.2.1") { |name| resolved << name }).to eq("192.0.2.1")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.05
    address, worker = await_result(driver.calls)
    expect(address).to eq("192.0.2.1")
    expect(worker).not_to eq(Thread.current)
    expect(driver.timeouts).to eq([0.5])
    driver.answers << "host.example"
    expect(await_result(resolved)).to eq("host.example")
    expect(resolver.request("192.0.2.1")).to eq("host.example")
    expect(driver.calls).to be_empty
  end

  it "coalesces simultaneous equivalent IPv6 addresses and delivers both callbacks" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver)
    resolved = Queue.new
    resolver.request("2001:db8::1") { |name| resolved << [:first, name] }
    expect(await_result(driver.calls).first).to eq("2001:db8::1")
    expect(resolver.request("2001:0DB8:0:0:0:0:0:1") { |name| resolved << [:second, name] }).to eq("2001:0DB8:0:0:0:0:0:1")
    driver.answers << "ipv6.example"
    expect([await_result(resolved), await_result(resolved)]).to eq([[:first, "ipv6.example"], [:second, "ipv6.example"]])
    expect(driver.calls).to be_empty
  end

  it "ignores hostnames, malformed addresses and network prefixes without querying DNS" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver)
    ["example.org", "999.0.0.1", "192.0.2.1/24", "2001:db8::/32", ""].each do |address|
      expect(resolver.request(address) { raise "unexpected callback" }).to eq(address)
    end
    expect(driver.calls).to be_empty
  end

  it "bounds pending work without blocking and allows a dropped request to be retried" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver, limit: 1)
    resolved = Queue.new
    resolver.request("192.0.2.1") { |name| resolved << name }
    await_result(driver.calls)
    resolver.request("192.0.2.2") { |name| resolved << name }
    expect(resolver.request("192.0.2.3") { raise "queue overflow callback" }).to eq("192.0.2.3")
    driver.answers << "one.example"
    expect(await_result(resolved)).to eq("one.example")
    expect(await_result(driver.calls).first).to eq("192.0.2.2")
    driver.answers << "two.example"
    expect(await_result(resolved)).to eq("two.example")
    resolver.request("192.0.2.3") { |name| resolved << name }
    expect(await_result(driver.calls).first).to eq("192.0.2.3")
    driver.answers << "three.example"
    expect(await_result(resolved)).to eq("three.example")
  end

  it "evicts the least recently used hostname within its cache limit" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver, limit: 2)
    resolved = Queue.new
    [1, 2].each do |number|
      resolver.request("192.0.2.#{number}") { |name| resolved << name }
      await_result(driver.calls)
      driver.answers << "host#{number}.example"
      await_result(resolved)
    end
    expect(resolver.request("192.0.2.1")).to eq("host1.example")
    resolver.request("192.0.2.3") { |name| resolved << name }
    await_result(driver.calls)
    driver.answers << "host3.example"
    await_result(resolved)
    expect(resolver.request("192.0.2.1")).to eq("host1.example")
    expect(resolver.request("192.0.2.2")).to eq("192.0.2.2")
    expect(await_result(driver.calls).first).to eq("192.0.2.2")
    driver.answers << "host2.example"
  end

  it "caches unsuccessful lookups and retries them after thirty seconds" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver)
    allow(resolver).to receive(:now).and_return(100.0)
    resolver.request("192.0.2.1") { raise "negative callback" }
    await_result(driver.calls)
    driver.answers << Resolv::ResolvError.new("not found")
    resolved = Queue.new
    resolver.request("192.0.2.2") { |name| resolved << name }
    await_result(driver.calls)
    driver.answers << "barrier.example"
    await_result(resolved)
    expect(resolver.request("192.0.2.1")).to eq("192.0.2.1")
    expect(driver.calls).to be_empty
    allow(resolver).to receive(:now).and_return(130.1)
    resolver.request("192.0.2.1")
    expect(await_result(driver.calls).first).to eq("192.0.2.1")
    driver.answers << "recovered.example"
  end

  it "closes a slow lookup within its timeout and suppresses queued and late callbacks" do
    driver = ControlledReverseLookup.new
    resolver = resolver_for(driver, timeout: 0.05)
    resolved = Queue.new
    resolver.request("192.0.2.1") { |name| resolved << name }
    _address, worker = await_result(driver.calls)
    resolver.request("192.0.2.2") { |name| resolved << name }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resolver.close
    # Ruby's timeout thread can be delayed on loaded runners. Still reject a
    # shutdown that waits indefinitely for the blocked lookup's answer.
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(worker.join(1)).to eq(worker)
    expect(driver.closed).to be true
    expect(resolved).to be_empty
    expect(driver.calls).to be_empty
    expect(resolver.request("192.0.2.3") { |name| resolved << name }).to eq("192.0.2.3")
    expect { resolver.close }.not_to raise_error
  end

  it "rejects invalid cache limits and timeouts before creating a worker" do
    [0, -1, Float::INFINITY, Float::NAN].each do |timeout|
      expect { described_class.new(timeout: timeout) }.to raise_error(ArgumentError)
    end
    [0, -1, 1.5].each do |limit|
      expect { described_class.new(limit: limit) }.to raise_error(ArgumentError)
    end
  end
end
