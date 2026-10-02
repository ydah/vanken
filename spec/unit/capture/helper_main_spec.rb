# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "vanken/capture/helper_main"
require "vanken/capture/launcher"

RSpec.describe Vanken::Capture::HelperMain do
  let(:interface) { {name: "test0", linktype: 1} }
  let(:source) { double("source", linktype: 1, backend: :socket, interfaces: [interface], stats: {received: 1, dropped: 0, if_dropped: 0, captured: 1}, close: nil) }
  let(:writer) { double("writer", :<< => nil, flush: nil, write_stats: nil, close: nil) }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  before do
    allow(Process).to receive_messages(uid: 1000, euid: 1000)
    allow(Vanken::Gateway::Interfaces).to receive(:find).with("test0").and_return(interface)
    allow(Vanken::Gateway::LiveCapture).to receive(:open).and_return(source)
    allow(Vanken::Gateway::FileWriter).to receive(:open).and_return(writer)
  end

  it "writes packets with a bounded receive timeout, finishes stats, and keeps controls off stdout" do
    packet = double("packet")
    allow(source).to receive(:stopped?).and_return(false, true)
    expect(source).to receive(:next_packet).with(timeout: 0.05).and_return(packet)
    expect(writer).to receive(:<<).with(packet)
    input, held = IO.pipe
    begin
      result = described_class.new(stdin: input, stdout: stdout, stderr: stderr).run(%w[-i test0])
      expect(result).to eq(0)
      events = stderr.string.lines.map { |line| JSON.parse(line) }
      expect(events.map { |e| e["type"] }).to eq(%w[hello started stopped])
      expect(events.last["reason"]).to eq("source_closed")
      expect(stdout.string).to eq("")
      expect(writer).to have_received(:write_stats).with(source.stats)
      expect(source).to have_received(:close)
    ensure
      input.close
      held.close
    end
  end

  it "stops when the parent closes stdin" do
    allow(source).to receive(:stopped?).and_return(false)
    allow(source).to receive(:next_packet) { sleep 0.01; nil }
    expect(described_class.new(stdin: StringIO.new, stdout: stdout, stderr: stderr).run(%w[-i test0])).to eq(0)
    expect(JSON.parse(stderr.string.lines.last)["reason"]).to eq("stdin_closed")
  end

  it "flushes output at 50ms and sends one-second stats using the monotonic clock" do
    allow(source).to receive(:stopped?).and_return(false, false, true)
    allow(source).to receive(:next_packet).and_return(nil)
    input, held = IO.pipe
    helper = described_class.new(stdin: input, stdout: stdout, stderr: stderr)
    allow(helper).to receive(:monotonic).and_return(0.0, 0.06, 1.06)
    begin
      expect(helper.run(%w[-i test0])).to eq(0)
      expect(writer).to have_received(:flush).twice
      expect(stderr.string.lines.map { |line| JSON.parse(line)["type"] }).to include("stats")
    ensure
      input.close
      held.close
    end
  end

  it "refuses privileged capture without a non-root drop target" do
    allow(Process).to receive_messages(uid: 0, euid: 0)
    expect(described_class.new(stdin: StringIO.new, stdout: stdout, stderr: stderr, env: {}).run(%w[-i test0])).to eq(3)
    expect(Vanken::Gateway::LiveCapture).not_to have_received(:open)
    expect(JSON.parse(stderr.string.lines.last)).to include("type" => "error", "code" => "permission_denied", "fatal" => true)
  end

  it "reports invalid command line input as exit 2" do
    expect(described_class.new(stdin: StringIO.new, stdout: stdout, stderr: stderr).run(%w[--unknown])).to eq(2)
    expect(JSON.parse(stderr.string.lines.last)["fatal"]).to be(true)
  end

  it "reports writer failures as write_failed and closes the source" do
    allow(Vanken::Gateway::FileWriter).to receive(:open).and_raise(Vanken::FileError, "disk is full")
    expect(described_class.new(stdin: StringIO.new, stdout: stdout, stderr: stderr).run(%w[-i test0])).to eq(1)
    expect(JSON.parse(stderr.string.lines.last)).to include("type" => "error", "code" => "write_failed")
    expect(source).to have_received(:close)
  end
end

RSpec.describe "standalone capture helper lifecycle" do
  %w[signal stdin_closed].each do |reason|
    it "preserves binary pcapng and exits cleanly within one second on #{reason}" do
      Dir.mktmpdir do |directory|
        script = File.join(directory, "helper.rb")
        File.write(script, <<~RUBY)
          require "vanken/capture/helper_main"
          module Vanken::Gateway::Interfaces
            def self.find(name) = {name: name, linktype: 1}
          end
          class FakeSource
            def linktype = 1
            def backend = :socket
            def stopped? = false
            def close; end
            def stats = {received: 1, dropped: 0, if_dropped: 0, captured: 1}
            def next_packet(timeout:)
              sleep timeout
              return if @sent
              @sent = true
              Redhound::Packet.new("packet".b, timestamp_ns: 1_790_900_000_000_000_000, linktype: 1)
            end
          end
          class Vanken::Gateway::LiveCapture
            def self.open(**options) = FakeSource.new
          end
          exit Vanken::Capture::HelperMain.new.run(ARGV)
        RUBY
        lib = File.expand_path("../../../lib", __dir__)
        paths = [lib] + Gem.loaded_specs.fetch("redhound").full_require_paths
        launcher = Vanken::Capture::Launcher.new(direct_command: [RbConfig.ruby, "-I", paths.join(File::PATH_SEPARATOR), script])
        handle = launcher.launch(%w[-i test0 --stats-interval 0.05], strategy: :direct)
        events = []
        while (line = handle.stderr.gets)
          events << JSON.parse(line)
          break if events.last["type"] == "stats"
        end
        expect(events.last["type"]).to eq("stats")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reason == "signal" ? Process.kill("TERM", handle.pid) : handle.stdin.close
        expect(handle.wait(timeout: 1)&.success?).to be(true)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        events += handle.stderr.readlines.map { |line| JSON.parse(line) }
        expect(events.last).to include("type" => "stopped", "reason" => reason)
        reader = Redhound.open(StringIO.new(handle.stdout.read))
        expect(reader.next_packet.data).to eq("packet".b)
        reader.close
      ensure
        handle&.close
      end
    end
  end
end
