#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require "json"
require "vanken/ui/application"

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
Dir.mktmpdir("vanken-smoke-") do |directory|
  preferences = Vanken::Config::Preferences.new(directory: directory)
  ui = Vanken::UI::Application.new(preferences: preferences)
  payload = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".b
  tcp = [51514, 80, 101, 201, 0x5018, 65_535, 0, 0].pack("nnNNnnnn") + payload
  ip = [0x45, 0, 20 + tcp.bytesize, 1, 0, 64, 6, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
  bytes = ["0200000000020200000000010800"].pack("H*") + ip + tcp
  frames = Enumerator.new do |stream|
    256.times do |index|
      stream << Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: 1_700_000_000_000_000_000 + (index * 1_000_000),
        original_length: bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
    end
  end
  document = Vanken::App::Document.new(preferences: preferences).ingest(frames).wait
  raise document.error if document.error
  ui.attach_document(document)
  ui.select_packet(1)
  10.times { ui.app.executor.drain; ui.window.tick }
  raise "native packet selection did not complete" unless ui.selected_number == 1 && ui.detail_nodes.any?
  ui.tree.expand("ipv4")
  ttl = ui.detail_nodes.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
  ui.select_detail(ttl)
  ui.copy_bytes(:hex)
  ui.set_filter("tcp.port == 80")
  ui.apply_filter
  ui.document.wait
  raise "native filtering failed" unless ui.document.displayed_count == 256
  pipeline_samples = []
  samples = Array.new(120) do
    ui.app.executor.drain
    ui.window.request_frame
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ui.window.tick
    pipeline_samples << ui.window.frame_stats.fetch(:frame_ms)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end.sort
  pipeline_samples.sort!
  ui.window.device.write_png(ENV.fetch("SNAPSHOT")) if ENV["SNAPSHOT"]
  puts JSON.pretty_generate(ruby: RUBY_VERSION, platform: RUBY_PLATFORM, frames: 120,
    tick_p50_ms: samples[60], tick_p95_ms: samples[114], tick_max_ms: samples.last,
    frame_p50_ms: pipeline_samples[60], frame_p95_ms: pipeline_samples[114], pipeline: ui.window.frame_stats)
ensure
  ui&.close
end
