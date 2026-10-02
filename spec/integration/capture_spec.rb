# frozen_string_literal: true

require "spec_helper"
require "open3"
require "stringio"
require "io/wait"
require "vanken/capture/launcher"
require "vanken/capture/control_protocol"
require "vanken/gateway/file_reader"

RSpec.describe "privileged live capture" do
  before do
    skip "requires the isolated Linux capture environment" unless ENV["VANKEN_NETNS"] == "1" && RUBY_PLATFORM.include?("linux")
  end

  it "drops privileges, captures veth traffic, writes statistics, and stops without leaving a child" do
    launcher = Vanken::Capture::Launcher.new
    handle = launcher.launch(%w[-i vkn-host --filter icmp --backend socket --no-promiscuous --stats-interval 0.05], strategy: :sudo)
    controls = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until controls.last&.fetch("type") == "started"
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "capture helper did not start: #{controls.inspect}" unless remaining.positive? && handle.stderr.wait_readable(remaining)
      line = handle.stderr.gets
      raise "capture helper exited before starting: #{controls.inspect}" unless line
      event = Vanken::Capture::ControlProtocol.parse(line)
      controls << event if event
      raise "capture helper error: #{event.inspect}" if event && event["type"] == "error"
    end
    expect(controls.last["privileges_dropped"]).to be(true)
    helper_pid = controls.find { |event| event["type"] == "hello" }.fetch("pid")
    identities, status = Open3.capture2("ps", "-o", "uid=,euid=", "-p", helper_pid.to_s)
    expect(status.success?).to be(true)
    expect(identities.split.map { |id| Integer(id) }).to eq([Process.uid, Process.uid])
    _output, ping_status = Open3.capture2e("ping", "-c", "3", "-W", "1", "192.0.2.2")
    expect(ping_status.success?).to be(true)
    expect(handle.stop(timeout: 3)&.success?).to be(true)
    controls += handle.stderr.readlines.filter_map { |line| Vanken::Capture::ControlProtocol.parse(line) }
    expect(controls.last["type"]).to eq("stopped")
    expect(controls.last.fetch("stats").fetch("captured")).to be >= 3
    reader = Vanken::Gateway::FileReader.new(StringIO.new(handle.stdout.read))
    frames = []
    loop do
      captured_frame = reader.next_frame
      break unless captured_frame

      frames << captured_frame
    end
    expect(frames.length).to be >= 3
    expect(frames).to all(have_attributes(linktype: 1))
    expect { Process.waitpid(handle.pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  ensure
    reader&.close
    handle&.close
  end
end
