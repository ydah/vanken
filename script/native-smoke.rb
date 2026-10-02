#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require "json"
require "vanken/ui/application"
require_relative "generate_fixtures"

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
Dir.mktmpdir("vanken-smoke-") do |directory|
  preferences = Vanken::Config::Preferences.new(directory: directory)
  ui = Vanken::UI::Application.new(preferences: preferences)
  payload = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".b
  tcp = [51514, 80, 101, 201, 0x5018, 65_535, 0, 0].pack("nnNNnnnn") + payload
  ip = [0x45, 0, 20 + tcp.bytesize, 1, 0, 64, 6, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
  bytes = ["0200000000020200000000010800"].pack("H*") + ip + tcp
  gate = Queue.new
  rate = 5_000
  ingestion_finished = nil
  produced = 0
  incoming = VankenFixtures.udp("native smoke", destination: 54_321)
  frames = Enumerator.new do |stream|
    256.times do |index|
      stream << Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: 1_700_000_000_000_000_000 + (index * 1_000_000),
        original_length: bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
    end
    gate.pop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    (rate * 5).times do |index|
      stream << Vanken::Core::Frame.new(bytes: incoming, timestamp_ns: 1_700_000_000_256_000_000 + (index * 200_000),
        original_length: incoming.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 257)
      produced = index + 1
      if (index + 1) % 100 == 0
        remaining = (index + 1).fdiv(rate) - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        sleep(remaining) if remaining.positive?
      end
    end
    ingestion_finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  document = Vanken::App::Document.new(preferences: preferences,
    on_update: ->(*) { ui.app.executor.post { ui.changed } }).ingest(frames, live: true)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  until document.count == 256
    raise document.error if document.error
    raise "native initial analysis timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep(0.005)
  end
  raise document.error if document.error
  ui.attach_document(document)
  ui.select_packet(1)
  10.times { ui.app.executor.drain; ui.window.tick }
  raise "native packet selection did not complete" unless ui.selected_number == 1 && ui.detail_nodes.any?
  ui.tree.expand("ipv4")
  ttl = ui.detail_nodes.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
  ui.select_detail(ttl)
  ui.copy_bytes(:hex)
  ui.set_filter("tcp.port == 80 || udp.port == 54321")
  ui.apply_filter
  sleep(0.005) while document.progress
  raise "native filtering failed" unless ui.document.displayed_count == 256
  100.times { ui.app.executor.drain; ui.window.request_frame; ui.window.tick }
  gate << true
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  until document.count >= 512 && ui.packet_source.packet_count >= 512
    raise document.error if document.error
    raise "native live analysis did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    ui.app.executor.drain
    sleep(0.005)
  end
  initial_count, initial_durable = document.count, document.store.durable_count
  initial_produced = produced
  measurement_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  active = []
  pipeline_samples = []
  samples = Array.new(120) do
    ui.app.executor.drain
    ui.window.request_frame
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ui.window.tick
    pipeline_samples << ui.window.frame_stats.fetch(:frame_ms)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    active << pipeline_samples.last unless ingestion_finished
    sleep([(1.0 / 60) - elapsed, 0.001].max)
    elapsed * 1000
  end.sort
  sampled_count, sampled_durable = document.count, document.store.durable_count
  measurement_finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sampled_produced = produced
  measurement_seconds = measurement_finished - measurement_started
  active_seconds = [ingestion_finished || measurement_finished, measurement_finished].min - measurement_started
  pipeline_samples.sort!
  document.wait(30)
  raise document.error if document.error
  raise "native live ingestion lost frames" unless document.count == 25_256 && document.displayed_count == 25_256
  raise "native drawing did not overlap ingestion" if active.empty?
  raise "native live acquisition did not advance while drawing" unless sampled_count > initial_count && sampled_durable > initial_durable
  raise "native live source missed its measured rate" unless (sampled_produced - initial_produced) >= ((rate * active_seconds) - 512)
  ui.app.executor.drain
  ui.window.request_frame
  ui.window.tick
  ui.window.device.write_png(ENV.fetch("SNAPSHOT")) if ENV["SNAPSHOT"]
  puts JSON.pretty_generate(ruby: RUBY_VERSION, platform: RUBY_PLATFORM, frames: 120,
    tick_p50_ms: samples[59], tick_p95_ms: samples[113], tick_max_ms: samples.last,
    frame_p50_ms: pipeline_samples[59], frame_p95_ms: pipeline_samples[113], pipeline: ui.window.frame_stats,
    ingestion: {frames_per_second: rate, received_frames: 25_000, active_samples: active.size,
      active_frame_p95_ms: active.sort[(active.size * 0.95).ceil - 1],
      measurement_seconds: measurement_seconds, initial_analyzed: initial_count, analyzed_after_sampling: sampled_count,
      initial_durable: initial_durable, durable_after_sampling: sampled_durable,
      source_frames_during_sampling: sampled_produced - initial_produced,
      source_frames_per_second: (sampled_produced - initial_produced) / active_seconds,
      analyzed_frames_per_second: (sampled_count - initial_count) / measurement_seconds})
ensure
  gate << true if gate
  ui&.close
end
