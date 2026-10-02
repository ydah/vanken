# frozen_string_literal: true

# Run: bundle exec ruby --yjit script/benchmark.rb [frames=200000] [ui_samples=120] [process_workers=0]
require "vanken"
require "zaniah/ui"
require "objspace"
require "json"
require "open3"
require "rbconfig"
require "vanken/gateway/display_capture_filter"

module VankenBenchmark
  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def retained_bytes = (GC.start; ObjectSpace.memsize_of_all)
  def rss_bytes(pid = Process.pid)
    return nil if RUBY_PLATFORM.match?(/mswin|mingw/)
    value, status = Open3.capture2e("ps", "-o", "rss=", "-p", pid.to_s)
    status.success? ? Integer(value.strip) * 1024 : nil
  rescue Errno::ENOENT, Errno::EPERM, Errno::EACCES, ArgumentError
    nil
  end
  def check(condition, message)
    raise message unless condition
  end

  # A fixed valid Ethernet/IPv4/UDP datagram, streamed without retaining frames.
  def datagram
    payload = "vanken benchmark".b
    ip = [0x45, 0, 28 + payload.bytesize, 0, 0, 64, 17, 0, 0xc0000201, 0xc6336402].pack("CCnnnCCnNN")
    checksum = ip.unpack("n*").sum
    2.times { checksum = (checksum & 0xffff) + (checksum >> 16) }
    ip[10, 2] = [~checksum & 0xffff].pack("n")
    ["0200000000020200000000010800"].pack("H*") + ip + [32_123, 54_321, 8 + payload.bytesize, 0].pack("n4") + payload
  end

  class Frames
    attr_reader :produced, :started_at, :finished_at
    def initialize(count, rate: nil)
      @count, @rate, @bytes = count, rate, VankenBenchmark.datagram.freeze
      @produced = 0
    end

    def each
      started = @started_at = VankenBenchmark.now
      @count.times do |index|
        yield Vanken::Core::Frame.new(bytes: @bytes, timestamp_ns: 1_700_000_000_000_000_000 + (index * 1_000_000),
          original_length: @bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
        @produced = index + 1
        if @rate && (index + 1) % 100 == 0
          remaining = (index + 1).fdiv(@rate) - (VankenBenchmark.now - started)
          sleep(remaining) if remaining.positive?
        end
      end
      @finished_at = VankenBenchmark.now
    end
  end

  class ReceiverDocument
    attr_reader :store, :error
    def initialize = @store = Vanken::Core::FrameStore.new
    def cancelled? = false
    def signal; end
    def receiving_done; end
    def fail(error) = @error = error
  end

  class MillionRows
    attr_reader :count, :calls
    def initialize(count) = (@count, @calls = count, 0)
    def row_id(index) = index + 1
    def cell(index, key)
      @calls += 1
      case key
      when :no then (index + 1).to_s
      when :time then format("%.6f", index * 0.001)
      when :source then "192.0.2.1"
      when :destination then "198.51.100.2"
      when :protocol then "UDP"
      when :length then "58"
      when :info then "32123 → 54321 Len=16"
      end
    end
  end

  def receiver(count)
    before = retained_bytes
    document = ReceiverDocument.new
    started = now
    Vanken::Capture::Receiver.new(document, Frames.new(count)).run
    seconds = now - started
    raise document.error if document.error
    check(document.store.durable_count == count, "receiver lost frames")
    retained = retained_bytes - before
    {seconds: seconds.round(4), frames_per_second: (count / seconds).round, retained_heap_bytes_per_frame: (retained.fdiv(count)).round(2)}
  ensure
    document&.store&.close
  end

  def document(count, process_workers: 0, ui_samples: nil)
    before = retained_bytes
    rss_before = rss_bytes
    document = Vanken::App::Document.new
    rss_samples, sampling = [], true
    sampler = Thread.new do
      while sampling
        analyzer = document.instance_variable_get(:@analyzer)
        pid = analyzer.pid if analyzer.respond_to?(:pid)
        parent_rss, worker_rss = rss_bytes, pid && rss_bytes(pid)
        rss_samples << [parent_rss, worker_rss] if parent_rss && worker_rss
        sleep(0.25)
      end
    end
    started = now
    document.ingest(Frames.new(count)).wait(900)
    seconds = now - started
    sampling = false
    sampler.join
    raise document.error if document.error
    check(document.count == count && document.store.durable_count == count, "document lost frames")
    check(document.columns[1][:protocol] == "UDP", "generated packet did not decode as UDP")
    check(document.annotations.experts.empty?, "generated datagrams had unexpected diagnostics")
    retained = retained_bytes - before
    rss_after = rss_bytes
    worker_baseline = rss_samples.first&.last
    combined_peak = rss_samples.map(&:sum).max
    combined_increment = rss_before && worker_baseline && combined_peak && (combined_peak - rss_before - worker_baseline)
    result = {seconds: seconds.round(4), frames_per_second: (count / seconds).round,
              retained_heap_bytes_per_frame: retained.fdiv(count).round(2),
              rss_before_bytes: rss_before, rss_after_bytes: rss_after,
              rss_bytes_per_frame: rss_before && rss_after ? ((rss_after - rss_before).fdiv(count)).round(2) : nil,
              analyzer_first_sample_rss_bytes: worker_baseline, parent_and_analyzer_peak_rss_bytes: combined_peak,
              parent_and_analyzer_peak_increment_bytes_per_frame: combined_increment&.fdiv(count)&.round(2), rss_sample_interval_seconds: 0.25}
    puts JSON.generate(phase: "ingest_and_analyze", frames: count, **result)

    expression = "udp && udp.port == 54321"
    check(Vanken::Core::DisplayFilter.compile(expression, catalog: document.catalog).fast?, "filter was not on the fast path")
    started = now
    document.apply_filter(expression).wait(120)
    filter_seconds = now - started
    raise document.error if document.error
    check(document.displayed_count == count, "fast filter lost matching frames")
    filtered_retained = retained_bytes - before
    rss_filtered = rss_bytes
    result.merge!(filter_seconds: filter_seconds.round(4), filter_expression: expression,
      filtered_retained_heap_bytes_per_frame: filtered_retained.fdiv(count).round(2),
      filtered_rss_bytes: rss_filtered,
      filtered_rss_bytes_per_frame: rss_before && rss_filtered ? ((rss_filtered - rss_before).fdiv(count)).round(2) : nil)
    if process_workers.positive?
      expression = "ip.ttl == 64"
      check(!Vanken::Core::DisplayFilter.compile(expression, catalog: document.catalog).fast?, "process filter unexpectedly used the fast path")
      pool = Zaniah::ProcessPool.new(workers: process_workers, handler: "Vanken::Capture::FilterWorker",
        requires: [File.expand_path("../lib/vanken/capture/filter_worker.rb", __dir__)],
        load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
      document.scanner = ->(payload) { pool.submit(payload) }
      started = now
      document.apply_filter(expression).wait(120)
      seconds = now - started
      raise document.error if document.error
      check(document.displayed_count == count, "process filter lost matching frames")
      result[:process_filter] = {expression: expression, workers: process_workers, seconds: seconds.round(4),
        matches: document.displayed_count, retained_parent_heap_bytes_per_frame: ((retained_bytes - before).fdiv(count)).round(2)}
      expression = "ip.addr == 192.0.2.1 && udp.port == 54321"
      check(Vanken::Gateway::DisplayCaptureFilter.new(expression).expression, "address filter did not convert to cBPF")
      started = now
      document.apply_filter(expression).wait(120)
      seconds = now - started
      raise document.error if document.error
      check(document.displayed_count == count, "cBPF worker filter lost matching frames")
      result[:capture_filter] = {expression: expression, workers: process_workers, seconds: seconds.round(4), matches: document.displayed_count}
    end
    puts JSON.generate(phase: "display_filters", **result.slice(:filter_seconds, :filtered_rss_bytes, :filtered_rss_bytes_per_frame, :process_filter, :capture_filter))
    result[:application_ui] = application_ui(document, ui_samples) if ui_samples
    result
  ensure
    sampling = false
    sampler&.join
    document&.close
    pool&.shutdown
  end

  def ui(count, samples, ingestion_rate: nil)
    app = Zaniah::App.new
    window = app.open_window(backend: :headless, width: 1200, height: 420)
    font = File.join(Gem.loaded_specs.fetch("zaniah").full_gem_path, "assets/fonts/Abel-Regular.ttf")
    window.text_system = Zaniah::TextSystem::Renderer.new(font: Alhena::Font.open(font), font_db: Zaniah::TextSystem::FontDB.new(paths: []))
    source = MillionRows.new(count)
    columns = [[:no, 72], [:time, 120], [:source, 140], [:destination, 150], [:protocol, 90], [:length, 72], [:info, 500]].map { |key, width| {key: key, width: width} }
    table = Zaniah::UI::VirtualTable.new(source, columns: columns, height: 420, row_height: 22)
    # Measure the public scene pipeline, including real shaping and accessibility.
    # The Ruby software pixel rasterizer does not represent native GPU presentation.
    20.times { window.render(table, present: false) }
    if ingestion_rate
      document = Vanken::App::Document.new
      ingestion_started = now
      document.ingest(Frames.new(ingestion_rate * 5, rate: ingestion_rate))
    end
    concurrent_times = []
    stage_times = Hash.new { |hash, key| hash[key] = [] }
    times = samples.times.map do |index|
      table.scroll_to((index * 7919) % (count - 20), align: :start)
      analyzing = document&.loading?
      started = now
      window.render(table, present: false)
      elapsed = now - started
      %i[frame_ms layout_ms prepaint_ms paint_ms].each { |key| stage_times[key] << window.frame_stats.fetch(key) }
      if document
        concurrent_times << (elapsed * 1000) if analyzing
        document.frame_latency = elapsed
        # A 60 Hz scheduling opportunity while real receiver/analyzer threads run.
        sleep([(1.0 / 60) - elapsed, 0].max)
      end
      elapsed * 1000
    end.sort
    check(table.body.children.size < 25, "virtual table constructed too many rows")
    result = {source_rows: count, samples: samples, visible_rows: table.body.children.size,
     p50_ms: times[(samples * 0.50).ceil - 1].round(3), p95_ms: times[(samples * 0.95).ceil - 1].round(3),
     max_ms: times.last.round(3), font: File.basename(font),
     pipeline_p95_ms: stage_times.transform_values { |values| values.sort[(samples * 0.95).ceil - 1].round(3) },
     backend: "headless layout, prepaint, scene paint, accessibility; present: false (pixel raster excluded)"}
    if document
      document.wait(90)
      raise document.error if document.error
      check(document.count == ingestion_rate * 5, "concurrent ingestion lost frames")
      check(document.annotations.experts.empty?, "concurrent datagrams had unexpected diagnostics")
      check(!concurrent_times.empty?, "UI did not overlap ingestion")
      concurrent_times.sort!
      result[:ingestion] = {requested_frames_per_second: ingestion_rate, frames: document.count,
        seconds: (now - ingestion_started).round(4), active_samples: concurrent_times.size,
        active_p95_ms: concurrent_times[(concurrent_times.size * 0.95).ceil - 1].round(3)}
    end
    result
  ensure
    document&.close
    window&.close
    app&.executor&.shutdown
  end

  def application_ui(document, samples, ingestion_rate: nil)
    require "vanken/ui/application"
    require "tmpdir"
    Dir.mktmpdir("vanken-benchmark-") do |directory|
      preferences = Vanken::Config::Preferences.new(directory: directory)
      app = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
      if ingestion_rate
        gate = Queue.new
        incoming = Frames.new(ingestion_rate * 5, rate: ingestion_rate)
        frames = Enumerator.new do |stream|
          Frames.new(256).each { |frame| stream << frame }
          gate.pop
          incoming.each do |frame|
            stream << frame.with(number: frame.number + 256, timestamp_ns: frame.timestamp_ns + 256_000_000)
          end
        end
        document = Vanken::App::Document.new(on_update: ->(*) { app.app.executor.post { app.changed } }).ingest(frames, live: true)
        await_application(app, document) { document.count == 256 }
      end
      view = Vanken::UI::MainView.new(app)
      app.attach_document(document)
      app.window.render(view, present: false)
      app.select_packet(1)
      await_application(app, document) { app.selected_number == 1 && app.detail_nodes.any? }
      app.tree.expand("ipv4")
      ttl = app.detail_nodes.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
      check(ttl, "application packet details did not include TTL")
      app.tree.select_id(ttl.id)
      app.set_filter("udp && udp.port == 54321")
      app.apply_filter
      await_application(app, document) { document.progress.nil? }
      app.changed
      check(app.packet_source.count == document.displayed_count, "application source count was not refreshed")
      100.times { app.app.executor.drain; app.window.render(view, present: false) }
      if ingestion_rate
        ingestion_started = now
        gate << true
        await_application(app, document) { document.count >= 512 }
      end
      times, active_times, active_scene_times = [], [], []
      initial_rows = document.count
      initial_produced = incoming&.produced
      measurement_started = now
      stages = Hash.new { |hash, key| hash[key] = [] }
      samples.times do |index|
        app.app.executor.drain
        app.table.scroll_to((index * 7919) % (document.displayed_count - 20), align: :start) unless ingestion_rate
        active = ingestion_rate && !incoming.finished_at
        started = now
        app.window.render(view, present: false)
        elapsed = now - started
        times << (elapsed * 1000)
        active_times << (elapsed * 1000) if ingestion_rate && active
        active_scene_times << app.window.frame_stats.fetch(:frame_ms) if active
        %i[frame_ms layout_ms prepaint_ms paint_ms].each { |key| stages[key] << app.window.frame_stats.fetch(key) }
        document.frame_latency = elapsed
        sleep([(1.0 / 60) - elapsed, 0.001].max) if ingestion_rate
      end
      measurement_finished = now
      sampled_rows, sampled_produced = document.count, incoming&.produced
      times.sort!
      result = {source_rows: initial_rows, source_rows_after_sampling: sampled_rows, samples: samples, viewport: [1280, 800],
        p50_ms: times[(samples * 0.50).ceil - 1].round(3), p95_ms: times[(samples * 0.95).ceil - 1].round(3), max_ms: times.last.round(3),
        selected_packet: app.selected_number, selected_field: app.selected_node&.field,
        visible_packet_rows: app.table.body.children.size, visible_byte_rows: app.hex.body.children.size,
        pipeline_p95_ms: stages.transform_values { |values| values.sort[(samples * 0.95).ceil - 1].round(3) },
        backend: "complete headless MainView with system fonts and all panes; present: false (pixel raster excluded)"}
      if ingestion_rate
        document.wait(90)
        raise document.error if document.error
        check(document.count == 256 + (ingestion_rate * 5) && document.displayed_count == document.count, "growing application lost frames")
        check(!active_times.empty?, "complete application did not overlap ingestion")
        check(sampled_rows > initial_rows, "complete application analysis did not advance during rendering")
        active_seconds = [incoming.finished_at, measurement_finished].min - measurement_started
        received = sampled_produced - initial_produced
        active_times.sort!
        result[:ingestion] = {requested_frames_per_second: ingestion_rate, frames: document.count - 256,
          final_source_rows: document.count, seconds: (now - ingestion_started).round(4), active_samples: active_times.size,
          measurement_seconds: (measurement_finished - measurement_started).round(4),
          source_frames_during_sampling: received, source_frames_per_second: (received / active_seconds).round(2),
          source_met_requested_rate: received >= ((ingestion_rate * active_seconds) - 512),
          active_scene_p95_ms: active_scene_times.sort[(active_scene_times.size * 0.95).ceil - 1].round(3),
          active_p95_ms: active_times[(active_times.size * 0.95).ceil - 1].round(3)}
      end
      result
    ensure
      gate << true if gate
      app&.close
    end
  end

  def await_application(app, document)
    deadline = now + 15
    until yield
      raise document.error if document.error
      check(now < deadline, "application initialization timed out")
      app.app.executor.drain
      sleep(0.005)
    end
  end

  def run(count, samples, process_workers = 0)
    check(count.is_a?(Integer) && count >= 50 && samples.is_a?(Integer) && samples.positive?, "use at least 50 frames and one UI sample")
    check(process_workers.is_a?(Integer) && process_workers >= 0, "process workers must be a nonnegative integer")
    puts JSON.generate(ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, frames: count, bytes_per_frame: datagram.bytesize,
      memory_measure: "GC-collected parent retained heap and ps RSS; parent plus analyzer RSS sampled every 250ms; filter worker RSS and filesystem cache excluded")
    # Initialize shared dissector/catalog caches before measuring retained deltas.
    warm = Vanken::App::Document.new
    warm.ingest(Frames.new(50)).wait(30)
    raise warm.error if warm.error
    warm.close
    # Keep the one-million-frame receiver allocation out of the document RSS baseline.
    output, status = Open3.capture2(RbConfig.ruby, "--yjit", "-I#{File.expand_path('../lib', __dir__)}", "-r", File.expand_path(__FILE__),
      "-e", "puts JSON.generate(VankenBenchmark.receiver(Integer(ARGV.fetch(0))))", count.to_s)
    check(status.success?, "receiver benchmark failed")
    results = {frames: count, receiver: JSON.parse(output, symbolize_names: true)}
    puts JSON.generate(phase: "receiver_only", **results[:receiver])
    results[:document] = document(count, process_workers: process_workers, ui_samples: samples)
    results[:ui] = ui([count, 1_000_000].max, samples)
    results[:ui_during_ingestion] = ui(1_000_000, samples, ingestion_rate: 5_000)
    results[:application_ui_during_ingestion] = application_ui(nil, samples, ingestion_rate: 5_000)
    results[:targets] = {
      receiver_100k_pps: results[:receiver][:frames_per_second] >= 100_000,
      analyzer_15k_pps: results[:document][:frames_per_second] >= 15_000,
      retained_heap_200_bytes_per_frame: results[:document][:retained_heap_bytes_per_frame] <= 200,
      rss_200_bytes_per_frame: results[:document][:rss_bytes_per_frame] && results[:document][:rss_bytes_per_frame] <= 200,
      filtered_rss_200_bytes_per_frame: results[:document][:filtered_rss_bytes_per_frame] && results[:document][:filtered_rss_bytes_per_frame] <= 200,
      parent_and_analyzer_rss_200_bytes_per_frame: results[:document][:parent_and_analyzer_peak_increment_bytes_per_frame] && results[:document][:parent_and_analyzer_peak_increment_bytes_per_frame] <= 200,
      fast_filter_1m_in_3s: count == 1_000_000 ? results[:document][:filter_seconds] <= 3 : nil,
      headless_ui_p95_33ms: results[:ui][:p95_ms] <= 33,
      ui_during_5k_pps_p95_33ms: results[:ui_during_ingestion][:ingestion][:active_p95_ms] <= 33,
      application_ui_scene_p95_33ms: results[:document][:application_ui][:pipeline_p95_ms][:frame_ms] <= 33,
      application_ui_during_5k_pps_scene_p95_33ms: results[:application_ui_during_ingestion][:ingestion][:source_met_requested_rate] &&
        results[:application_ui_during_ingestion][:ingestion][:active_scene_p95_ms] <= 33
    }
    puts JSON.pretty_generate(results)
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  VankenBenchmark.run(Integer(ARGV.fetch(0, "200000")), Integer(ARGV.fetch(1, "120")), Integer(ARGV.fetch(2, "0")))
end
