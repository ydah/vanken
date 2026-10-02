#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"

# Real UI scene measurements; native event dispatch, rasterization and GPU
# presentation are excluded. render(present: false) includes accessibility.
module VankenCapturePerformance
  # Use the public window tick while retaining the headless scene-only scope.
  module SceneOnlyRender
    def render(element, **options)
      super(element, **options, present: false)
    end
  end

  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def check(condition, message) = (raise(message) unless condition)
  def percentile(values, fraction) = values.sort.fetch((values.size * fraction).ceil - 1)

  def datagram
    payload = "vanken latency".b
    ip = [0x45, 0, 28 + payload.bytesize, 0, 0, 64, 17, 0, 0xc0000202, 0xc0000201].pack("CCnnnCCnNN")
    sum = ip.unpack("n*").sum
    2.times { sum = (sum & 0xffff) + (sum >> 16) }
    ip[10, 2] = [~sum & 0xffff].pack("n")
    ["0200000000020200000000010800"].pack("H*") + ip + [32_123, 54_321, 8 + payload.bytesize, 0].pack("n4") + payload
  end

  def write_capture(path, min_bytes: 100_000_000)
    bytes = datagram
    record = [1_700_000_000, 0, bytes.bytesize, bytes.bytesize].pack("V4") + bytes
    count = ((min_bytes - 24).fdiv(record.bytesize)).ceil
    File.open(path, "wb", 0o600) do |file|
      file.write([0xa1b2c3d4, 2, 4, 0, 0, 65_535, 1].pack("VvvVVVV"))
      blocks, remainder = count.divmod(4096)
      block = record * 4096
      blocks.times { file.write(block) }
      file.write(record * remainder)
    end
    count
  end

  def send_traffic(host:, port:, rate:, duration:)
    check(rate.positive? && duration.positive?, "rate and duration must be positive")
    count = (rate * duration).round
    socket = UDPSocket.new
    socket.connect(host, port)
    started = now
    max_lateness = 0.0
    count.times do |index|
      socket.send([index + 1].pack("Q>") + ("vanken capture" * 4), 0)
      next unless (index + 1) % 5 == 0 || index + 1 == count
      remaining = ((index + 1).fdiv(rate)) - (now - started)
      max_lateness = [max_lateness, -remaining].max
      sleep(remaining) if remaining.positive?
    end
    finished = now
    elapsed = finished - started
    {sent: count, requested_rate: rate, requested_seconds: duration, seconds: elapsed,
      started_monotonic: started, finished_monotonic: finished,
      frames_per_second: count / elapsed, max_pacing_lateness_ms: max_lateness * 1000}
  ensure
    socket&.close
  end

  # received includes socket drops; captured counts packets read by the helper.
  # Kernel PACKET_STATISTICS resets on read; Redhound accumulates its deltas.
  # The timestamp belongs to that statistics read, not to the later GUI sample.
  def backlog_sample(stats:, durable:, analyzed:, seconds:)
    {seconds: seconds, helper_stats: stats, durable: durable, analyzed: analyzed,
      kernel_pending: stats.fetch(:received, 0) - stats.fetch(:dropped, 0) - stats.fetch(:captured, 0),
      helper_to_durable: stats.fetch(:captured, 0) - durable, analyzer_pending: durable - analyzed}
  end

  def verify_capture!(sender:, stats:, durable:, analyzed:)
    %i[dropped if_dropped freeze_count].each { |key| check(stats.fetch(key).zero?, "capture #{key}: #{stats.fetch(key)}") }
    expected = sender.fetch("sent")
    counts = {received: stats.fetch(:received), captured: stats.fetch(:captured), durable: durable, analyzed: analyzed}
    counts.each { |key, value| check(value == expected, "#{key}: #{value}, expected #{expected}") }
    true
  end

  def render_frame(ui, view)
    ui.app.executor.drain
    started = now
    ui.window.render(view, present: false)
    elapsed = now - started
    ui.document.frame_latency = elapsed if ui.document
    elapsed * 1000
  end

  def tick_frame(ui)
    ui.app.executor.drain
    previous_frame = ui.window.frame_number
    started = now
    ui.window.tick
    return unless ui.window.frame_number > previous_frame

    elapsed = now - started
    ui.document.frame_latency = elapsed if ui.document
    elapsed * 1000
  end

  def await_frame(ui, _view, timeout: 30)
    deadline = now + timeout
    rendered_at = now if ui.window.frame_number.positive?
    loop do
      ui.app.executor.drain
      previous_frame = ui.window.frame_number
      ui.window.tick
      rendered_at = now if ui.window.frame_number > previous_frame
      raise ui.document.error if ui.document&.error
      raise ui.capture.error if ui.capture.error
      return rendered_at if rendered_at && yield
      if now >= deadline
        snapshot = Zaniah::Inspection.snapshot(ui.window)
        raise "UI operation timed out: selected=#{ui.selected_number.inspect}, details=#{ui.detail_nodes.size}, " \
          "bytes=#{ui.selected_bytes.bytesize}, hex_rows=#{ui.hex.body.children.size}, " \
          "treeitems=#{snapshot.accessibility.query(role: :treeitem).size}, " \
          "hex_texts=#{snapshot.accessibility.query(role: :text, label: /Offset/).size}"
      end
      ui.app.executor.wait(0.05) unless ui.window.dirty? || ui.window.animation_active?
    end
  end

  def file_latencies(ui, view, directory, min_bytes:)
    path = File.join(directory, "initial-row.pcap")
    count = write_capture(path, min_bytes: min_bytes)
    started = now
    ui.open_file(path)
    rendered_at = await_frame(ui, view) do
      ui.packet_source.count.positive? && ui.packet_source.value(0, :protocol) == "UDP" &&
        Zaniah::Inspection.snapshot(ui.window).accessibility.query(role: :cell, label: "Protocol")
          .any? { |node, _| node.value == "UDP" }
    end
    first_ms = (rendered_at - started) * 1000
    first_verification_ms = (now - rendered_at) * 1000
    first_count = ui.document.count
    # Different packets, so these measure new background details work, not a
    # repeated selection of an already displayed packet.
    verification_times = []
    times = (1..20).map do |number|
      await_frame(ui, view) { ui.document.count >= number }
      started = now
      ui.select_packet(number)
      rendered_at = await_frame(ui, view) do
        next false unless ui.selected_number == number && ui.detail_nodes.any? &&
          ui.hex.bytes == ui.selected_bytes && ui.hex.body.children.any?
        snapshot = Zaniah::Inspection.snapshot(ui.window)
        details = snapshot.find(test_id: "vk.packet_details")
        bytes = snapshot.find(test_id: "vk.packet_bytes")
        details && bytes && details.children.any? && bytes.children.any? &&
          details.bounds.height.positive? && bytes.bounds.height.positive?
      end
      verification_times << ((now - rendered_at) * 1000)
      (rendered_at - started) * 1000
    end
    {file_bytes: File.size(path), file_frames: count, analyzed_at_first_row: first_count,
      latency_scope: "Production dirty-driven Window#tick and foreground wake. Operation through the render completing the verified scene. Inspection snapshot/assertion time after that render is excluded.",
      first_row_ms: first_ms, first_row_inspection_verification_ms: first_verification_ms,
      selection_samples: times.size,
      selection_p50_ms: percentile(times, 0.50), selection_p95_ms: percentile(times, 0.95),
      selection_max_ms: times.max, selection_ms: times,
      selection_inspection_verification_ms: verification_times,
      selection_inspection_verification_p95_ms: percentile(verification_times, 0.95),
      targets: {file_at_least_100mb: File.size(path) >= 100_000_000,
        first_row_1s: first_ms <= 1000, every_selection_50ms: times.max <= 50}}
  ensure
    doc = ui.document
    ui.attach_document(nil)
    doc&.close
    File.unlink(path) if path && File.exist?(path)
  end

  def live_capture(ui, view, reports:, rate:, duration:)
    check(Process.uid.positive? && Process.euid.positive?, "measurement UI must be unprivileged")
    socket = UDPSocket.new
    socket.bind("192.0.2.1", 54_321)
    # Drain the receiving UDP socket in a separate thread to avoid ICMP replies.
    sink = Thread.new { loop { socket.recv(65_535) } }
    sink.report_on_exception = false
    ui.capture.start(%w[-i vkn-host --filter udp\ dst\ port\ 54321 --direction in --backend socket --no-promiscuous --stats-interval 1])
    await_frame(ui, view) { ui.capture.capturing? && ui.document }
    started = now
    File.write(File.join(reports, "ready"), "ready\n", mode: "w", perm: 0o644)
    samples, frames, stages, frame_starts = [], [], [], []
    growth = []
    next_sample = 0.0
    selected = false
    last_rendered_count = ui.document.count
    drain_timeout = 600
    deadline = started + duration + drain_timeout
    last_progress_at, last_progress = started, [0, 0, 0]
    sender = nil
    loop do
      frame_start = now
      if (frame_ms = tick_frame(ui))
        frames << frame_ms
        stages << ui.window.frame_stats.fetch(:frame_ms)
        frame_starts << frame_start
        rendered_count = ui.document.count
        growth << (rendered_count > last_rendered_count)
        last_rendered_count = rendered_count
      end
      raise ui.capture.error if ui.capture.error
      raise ui.document.error if ui.document.error
      if !selected && ui.document.count.positive?
        ui.select_packet(1)
        selected = true
      end
      if ui.selected_number == 1 && ui.selected_node.nil?
        ui.tree.expand("ipv4")
        ttl = ui.detail_nodes.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
        ui.select_detail(ttl) if ttl
      end
      elapsed = now - started
      if elapsed >= next_sample
        analyzed = ui.document.count
        sample = backlog_sample(stats: ui.capture.stats, durable: ui.document.store.durable_count,
          analyzed: analyzed, seconds: elapsed)
        sample[:inspection_frame] = Zaniah::Inspection.snapshot(ui.window).frame.to_h
        samples << sample
        puts JSON.generate(phase: "live_sample", **sample)
        next_sample = elapsed + 1
      end
      sender_path = File.join(reports, "sender.json")
      sender ||= JSON.parse(File.read(sender_path)) if File.exist?(sender_path)
      progress = [ui.capture.stats.fetch(:captured, 0), ui.document.store.durable_count, ui.document.count]
      if progress != last_progress
        last_progress_at, last_progress = now, progress
      end
      if sender
        stats = ui.capture.stats
        expected = sender.fetch("sent") - stats.fetch(:dropped, 0)
        break if stats.fetch(:received, 0) >= sender.fetch("sent") && stats.fetch(:captured, 0) == expected &&
          ui.document.store.durable_count == expected && ui.document.count == expected
      end
      check(now - last_progress_at < 90, "live capture made no progress for 90 seconds")
      check(now < deadline, "live capture exceeded its #{drain_timeout}-second drain allowance")
      ui.app.executor.wait(0.05) unless ui.window.dirty? || ui.window.animation_active?
    end
    analyzed_at = now
    ui.capture.stop
    await_frame(ui, view) { ui.capture.wait(0) }
    stats = ui.capture.stats
    final = backlog_sample(stats: stats, durable: ui.document.store.durable_count, analyzed: ui.document.count, seconds: now - started)
    samples << final
    active_indices = frame_starts.each_index.select do |index|
      frame_starts[index] >= sender.fetch("started_monotonic") && frame_starts[index] < sender.fetch("finished_monotonic")
    end
    active_growth = active_indices.count { |index| growth[index] }
    check(!active_indices.empty? && active_growth.positive?, "UI frames did not overlap live document growth")
    active_frames = active_indices.map { |index| frames[index] }
    active_stages = active_indices.map { |index| stages[index] }
    result = {interface: "vkn-host", backend: "socket", direction: "in", filter: "udp dst port 54321",
      ui_loop: "Application.run: executor drain, dirty-driven window tick, foreground wait; only actual rendered frames are sampled",
      analysis_drain_seconds: [analyzed_at - sender.fetch("finished_monotonic"), 0].max,
      drain_allowance_seconds: drain_timeout, progress_timeout_seconds: 90,
      uid: Process.uid, euid: Process.euid, sender: sender, stats: stats, samples: samples,
      backlog_scope: "Kernel pending is measured at helper stats.ts. Helper-to-durable compares that last control sample with a later GUI count and may be negative; it is not an atomic pipe depth. Analyzer count is read before durable count. Final counts are exact after helper shutdown and drain.",
      ui_frames: frames.size, render_p50_ms: percentile(frames, 0.50), render_p95_ms: percentile(frames, 0.95),
      inspection_frame_p95_ms: percentile(stages, 0.95), render_max_ms: frames.max,
      ui_frames_during_actual_traffic: active_indices.size, ui_frames_with_analyzed_growth: growth.count(true),
      ui_frames_with_analyzed_growth_during_actual_traffic: active_growth,
      traffic_render_total_p95_ms: percentile(active_frames, 0.95),
      traffic_inspection_frame_p95_ms: percentile(active_stages, 0.95),
      selected_packet: ui.selected_number, selected_field: ui.selected_node&.field,
      maximum_kernel_pending: samples.map { |sample| sample[:kernel_pending] }.max,
      maximum_helper_to_durable: samples.map { |sample| sample[:helper_to_durable] }.max,
      maximum_analyzer_pending: samples.map { |sample| sample[:analyzer_pending] }.max,
      final: final, targets: {capture_integrity: false, sustained_5k_pps_300s: rate == 5000 && duration >= 300 &&
        sender.fetch("seconds") >= 300 && sender.fetch("frames_per_second") >= 4950,
        ui_inspection_frame_during_traffic_p95_33ms: percentile(active_stages, 0.95) <= 33}}
    # Save evidence before raising an integrity failure; CI uploads it even on failure.
    File.write(File.join(reports, "live.json"), JSON.pretty_generate(result) + "\n")
    result[:targets][:capture_integrity] = verify_capture!(sender: sender, stats: stats, durable: final[:durable], analyzed: final[:analyzed])
    File.write(File.join(reports, "live.json"), JSON.pretty_generate(result) + "\n")
    result
  rescue StandardError => error
    failure = {error: "#{error.class}: #{error.message}", helper_stats: ui.capture.stats,
      durable: ui.document&.store&.durable_count, analyzed: ui.document&.count, samples: samples,
      sender: sender, render_ms: frames, inspection_frame_ms: stages, frame_started_monotonic: frame_starts}
    File.write(File.join(reports, "failure.json"), JSON.pretty_generate(failure) + "\n")
    raise
  ensure
    sink&.kill
    sink&.join
    socket&.close
  end

  def run(reports:, rate: 5000, duration: 300, ui_only: false, min_bytes: 100_000_000)
    require "vanken/ui/application"
    RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
    Dir.mktmpdir("vanken-capture-performance-") do |directory|
      preferences = Vanken::Config::Preferences.new(directory: directory)
      preferences.set("capture.launcher", "sudo")
      ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
      view = Vanken::UI::MainView.new(ui)
      ui.window.extend(SceneOnlyRender)
      ui.window.draw { view }
      100.times { render_frame(ui, view) }
      result = {ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM,
        zaniah: Gem.loaded_specs.fetch("zaniah").version.to_s, viewport: [1280, 800],
        scope: "Production Application, real fonts, render(present: false): layout, prepaint, scene paint, accessibility. Native events, pixel rasterization and GPU presentation excluded.",
        file: file_latencies(ui, view, directory, min_bytes: min_bytes)}
      File.write(File.join(reports, "file-latency.json"), JSON.pretty_generate(result) + "\n")
      result[:live] = live_capture(ui, view, reports: reports, rate: rate, duration: duration) unless ui_only
      File.write(File.join(reports, "performance.json"), JSON.pretty_generate(result) + "\n")
      puts JSON.pretty_generate(result)
      result
    ensure
      ui&.close
    end
  end
end

if $PROGRAM_NAME == __FILE__
  reports = ENV.fetch("VANKEN_CAPTURE_REPORTS", "tmp/capture-results")
  rate = Integer(ENV.fetch("CAPTURE_RATE", "5000"))
  duration = Float(ENV.fetch("CAPTURE_DURATION", "300"))
  if ARGV.first == "--send"
    deadline = VankenCapturePerformance.now + 300
    until File.exist?(File.join(reports, "ready"))
      VankenCapturePerformance.check(VankenCapturePerformance.now < deadline, "UI did not become ready")
      sleep(0.05)
    end
    result = VankenCapturePerformance.send_traffic(host: "192.0.2.1", port: 54_321, rate: rate, duration: duration)
    path = File.join(reports, "sender.json")
    File.write("#{path}.tmp", JSON.pretty_generate(result) + "\n", mode: "w", perm: 0o644)
    File.rename("#{path}.tmp", path)
  else
    Dir.mkdir(reports) unless File.directory?(reports)
    VankenCapturePerformance.run(reports: reports, rate: rate, duration: duration, ui_only: ARGV.first == "--ui-only",
      min_bytes: Integer(ENV.fetch("CAPTURE_FILE_BYTES", "100000000")))
  end
end
