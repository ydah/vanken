# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require_relative "../../script/capture-performance"

RSpec.describe VankenCapturePerformance do
  it "measures live frames only when the application redraws its window" do
    window = double("window", frame_number: 0, tick: nil)
    document = double("document")
    executor = double("executor", drain: nil)
    ui = Struct.new(:app, :window, :document).new(Struct.new(:executor).new(executor), window, document)
    expect(window).not_to receive(:render)
    expect(described_class.tick_frame(ui)).to be_nil
    allow(window).to receive(:tick) { allow(window).to receive(:frame_number).and_return(1) }
    expect(document).to receive(:frame_latency=).with(be_a(Numeric))
    expect(described_class.tick_frame(ui)).to be_a(Float)
  end

  it "waits for background publication before drawing a clean window once" do
    window = Class.new do
      attr_reader :frame_number, :draws
      def initialize = (@frame_number = @draws = 0; @dirty = false)
      def dirty? = @dirty
      def animation_active? = false
      def request_frame = @dirty = true
      def render(*) = (@draws += 1; @frame_number += 1)
      def tick
        return unless dirty?
        @dirty = false
        render
      end
    end.new
    foreground = []
    published = false
    executor = double("executor")
    allow(executor).to receive(:drain) { foreground.shift&.call }
    expect(executor).to receive(:wait).with(0.05).once do
      expect(window.draws).to eq(0)
      foreground << -> { published = true; window.request_frame }
    end
    ui = Struct.new(:app, :window, :document, :capture).new(
      Struct.new(:executor).new(executor), window, nil, Struct.new(:error).new(nil))

    rendered_at = described_class.await_frame(ui, Object.new) do
      raise "unchanged scene redrawn while waiting for background work" if window.draws.positive? && !published
      published
    end

    expect(rendered_at).to be_a(Float)
    expect(window.draws).to eq(1)
  end

  it "checks every capture boundary and refuses loss hidden by a matching analyzer count" do
    sender = {"sent" => 10}
    stats = {captured: 10, received: 10, dropped: 0, if_dropped: 0, freeze_count: 0}
    expect(described_class.verify_capture!(sender: sender, stats: stats, durable: 10, analyzed: 10)).to be(true)
    expect { described_class.verify_capture!(sender: sender, stats: stats.merge(received: 11, dropped: 1), durable: 10, analyzed: 10) }
      .to raise_error(/dropped/)
    expect { described_class.verify_capture!(sender: sender, stats: stats, durable: 9, analyzed: 9) }
      .to raise_error(/durable/)
    expect { described_class.verify_capture!(sender: sender, stats: stats.merge(received: 11), durable: 10, analyzed: 10) }
      .to raise_error(/received/)
  end

  it "keeps the kernel, pipe, and analyzer backlogs separate with the statistics timestamp" do
    stats = {received: 100, dropped: 2, captured: 95, ts: 123.5}
    expect(described_class.backlog_sample(stats: stats, durable: 90, analyzed: 80, seconds: 1.25)).to eq(
      seconds: 1.25, helper_stats: stats, durable: 90, analyzed: 80,
      kernel_pending: 3, helper_to_durable: 5, analyzer_pending: 10)
  end

  it "streams a real capture of at least the requested size without retaining packet objects" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "latency.pcap")
      count = described_class.write_capture(path, min_bytes: 1000)
      expect(File.size(path)).to be >= 1000
      reader = Vanken::Gateway::FileReader.new(path)
      frames = reader.to_a
      expect(frames.length).to eq(count)
      expect(frames.first.bytes).to eq(described_class.datagram)
      expect(frames.last.number).to eq(count)
    ensure
      reader&.close
    end
  end

  it "paces the exact UDP count and encodes a sequence number in each datagram" do
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    result = described_class.send_traffic(host: "127.0.0.1", port: socket.addr[1], rate: 1000, duration: 0.01)
    sequences = Array.new(10) { socket.recv(64).unpack1("Q>") }
    expect(sequences).to eq((1..10).to_a)
    expect(result.fetch(:sent)).to eq(10)
    expect(result.fetch(:seconds)).to be >= 0.01
  ensure
    socket&.close
  end
end
