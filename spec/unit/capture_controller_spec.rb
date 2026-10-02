# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/app/capture_controller"
require_relative "../support/packets"

RSpec.describe Vanken::App::CaptureController do
  def eventually(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition was not reached" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def fake_launcher(directory, stop_message: true, startup_error: nil, close_control: false, pause_before_header: false)
    capture = File.join(directory, "input.pcapng")
    write_capture(capture, [frame, frame(tcp_bytes(seq: 101, flags: 24, payload: "tail"), number: 2)])
    helper = File.join(directory, "helper.rb")
    File.write(helper, <<~RUBY)
      require "json"
      STDERR.sync = STDOUT.sync = true
      emit = ->(type, fields = {}) { STDERR.puts JSON.generate(fields.merge(v: 1, type: type)) }
      emit.call("hello", pid: Process.pid)
      if #{startup_error.inspect}
        emit.call("error", code: "permission_denied", message: "not permitted", fatal: true)
        exit 3
      end
      Signal.trap("TERM") { }
      emit.call("started", interface: "test0", linktype: 1)
      STDERR.puts "plain log"
      STDERR.puts JSON.generate(v: 2, type: "error", message: "future version")
      sleep 0.001 until File.exist?(#{File.join(directory, "release-header").inspect}) if #{pause_before_header}
      STDOUT.write File.binread(#{capture.inspect})
      emit.call("stats", received: 2, dropped: 1, if_dropped: 0, captured: 2)
      STDERR.reopen(File::NULL, "w") if #{close_control}
      STDIN.read
      emit.call("stopped", reason: "stdin_closed", stats: {received: 2, dropped: 1, if_dropped: 0, captured: 2}) if #{stop_message}
    RUBY
    Vanken::Capture::Launcher.new(strategy: :direct, direct_command: [RbConfig.ruby, helper])
  end

  it "attaches the capture document before the first packet header arrives" do
    Dir.mktmpdir do |directory|
      documents = []
      marker = File.join(directory, "release-header")
      controller = described_class.new(launcher: fake_launcher(directory, pause_before_header: true),
        on_document: ->(doc) { documents << doc })
      controller.start(interface: "test0")
      eventually { controller.capturing? && controller.document }
      expect(controller.document).not_to be_nil
      expect(documents).to eq([controller.document])
      expect(controller.document.count).to eq(0)
      File.write(marker, "")
      eventually { controller.document.count == 2 }
      controller.stop.wait(3)
      expect(controller.state).to eq(:stopped)
    ensure
      File.write(marker, "") if marker
      controller&.close
    end
  end

  it "starts asynchronously, consumes controls, and drains both pending frames before stopping" do
    Dir.mktmpdir do |directory|
      documents = []
      controller = described_class.new(launcher: fake_launcher(directory), on_document: ->(doc) { documents << doc })
      expect(controller.start(interface: "test0")).to eq(controller)
      eventually { controller.capturing? && controller.document&.count == 2 }
      expect(controller.stats[:dropped]).to eq(1)
      expect(controller.error).to be_nil
      expect(documents).to eq([controller.document])
      expect(controller.document.dirty?).to be(true)
      expect(controller.stop).to eq(controller)
      expect(controller.wait(timeout: 3)).to eq(controller)
      expect(controller.state).to eq(:stopped)
      expect(controller.document.complete?).to be(true)
      expect(controller.document.count).to eq(2)
      expect(controller.document.store.read(2).bytes).to eq(frame(tcp_bytes(seq: 101, flags: 24, payload: "tail")).bytes)
      expect(controller.document.dirty?).to be(true)
    ensure
      controller&.close
    end
  end

  it "reports helper startup errors with their code and reaps the process" do
    Dir.mktmpdir do |directory|
      controller = described_class.new(launcher: fake_launcher(directory, startup_error: true))
      allow(controller).to(receive(:consume_control).and_wrap_original { |original, *args| sleep 0.05; original.call(*args) })
      controller.start(interface: "test0")
      expect(controller.wait(3)).to eq(controller)
      expect(controller.state).to eq(:failed)
      expect(controller.error.message).to eq("not permitted")
      expect(controller.error.code).to eq("permission_denied")
      expect(controller.running?).to be(false)
    ensure
      controller&.close
    end
  end

  it "treats stdout and control EOF without stopped as an unexpected failure" do
    Dir.mktmpdir do |directory|
      controller = described_class.new(launcher: fake_launcher(directory, stop_message: false))
      controller.start(interface: "test0")
      eventually { controller.document&.count == 2 }
      controller.stop.wait(3)
      expect(controller.state).to eq(:failed)
      expect(controller.error.message).to match(/stopped message/)
      expect(controller.document.count).to eq(2)
    ensure
      controller&.close
    end
  end

  it "rejects overlapping starts and allows another capture after cleanup" do
    Dir.mktmpdir do |directory|
      controller = described_class.new(launcher: fake_launcher(directory))
      controller.start(interface: "test0")
      expect { controller.start(interface: "test0") }.to raise_error(Vanken::CaptureError)
      eventually { controller.document&.count == 2 }
      previous = controller.document
      controller.stop.wait(3)
      controller.start(interface: "test0")
      eventually { controller.document != previous && controller.document&.count == 2 }
      expect(File.directory?(previous.store.directory)).to be(true)
      previous.close
      controller.stop.wait(3)
    ensure
      controller&.close
    end
  end

  it "stops the helper if its control channel closes while stdout is still open" do
    Dir.mktmpdir do |directory|
      controller = described_class.new(launcher: fake_launcher(directory, close_control: true))
      controller.start(interface: "test0")
      expect(controller.wait(3)).to eq(controller)
      expect(controller.state).to eq(:failed)
      expect(controller.error.message).to match(/control channel/)
    ensure
      controller&.close
    end
  end

  it "refuses a queued start after the controller has been closed" do
    Dir.mktmpdir do |directory|
      controller = described_class.new(launcher: fake_launcher(directory))
      controller.close
      expect { controller.start(interface: "test0") }.to raise_error(Vanken::CaptureError, /closed/)
    ensure
      controller&.close
    end
  end
end
