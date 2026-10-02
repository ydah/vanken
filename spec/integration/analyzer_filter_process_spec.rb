# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "zaniah"
require "zaniah/process_pool"
require "vanken/capture/filter_worker"
require_relative "../support/packets"

RSpec.describe "Stateful filters across isolated analysis" do
  def wait_until
    Timeout.timeout(5) { sleep(0.001) until yield }
  end

  def split_http_frames
    [frame(tcp_bytes(flags: 2), timestamp_ns: 1_000_000_000),
     frame(tcp_bytes(seq: 101, flags: 24, payload: "GE"), number: 2, timestamp_ns: 2_000_000_000),
     frame(tcp_bytes(seq: 103, flags: 24, payload: "T /split HTTP/1.1\r\nHost: example.test\r\n\r\n"),
       number: 3, timestamp_ns: 3_000_000_000)]
  end

  def worker_scanner
    @pool = Zaniah::ProcessPool.new(workers: 1, handler: "Vanken::Capture::FilterWorker",
      requires: [File.expand_path("../../lib/vanken/capture/filter_worker.rb", __dir__)],
      load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
    ->(payload) { @pool.submit(payload) }
  end

  def live_source(frames)
    incoming = Queue.new
    frames.each { |item| incoming << item }
    stopped = false
    source = Object.new
    source.define_singleton_method(:push) { |item| incoming << item }
    source.define_singleton_method(:next_frame) do |timeout:|
      incoming.pop(true)
    rescue ThreadError
      sleep(timeout) unless stopped
      nil
    end
    source.define_singleton_method(:eof?) { stopped && incoming.empty? }
    source.define_singleton_method(:stop) { stopped = true }
    source
  end

  def pending_scanner
    @submitted = Queue.new
    submitted = @submitted
    ->(payload) do
      task = Zaniah::Task.new
      submitted << [payload, task]
      task
    end
  end

  after do
    @release&.push(true)
    @documents&.each(&:close)
    @document&.close
    @pool&.shutdown
  end

  it "keeps live, direct, and named-worker matches on the original reassembled HTTP fields" do
    expression = 'http.request.method == "GET" and http.host == "example.test" and tcp.stream == 0'
    @document = Vanken::App::Document.new(scanner: worker_scanner)
    @document.apply_filter(expression).wait(2)
    @document.ingest(split_http_frames, live: true).wait(5)
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([3])
    expect(@document.packet_snapshot(3).values("http.request.method")).to eq(["GET"])
    expect(@document.details(3).flat_map(&:descendants).map(&:field)).to include("http.host")

    @document.scanner = nil
    @document.apply_filter(expression).wait(2)
    expect(@document.display_numbers).to eq([3])
    @document.scanner = ->(payload) { @pool.submit(payload) }
    @document.apply_filter(expression).wait(5)
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([3])
  end

  it "advances the live displayed predecessor only for matching frames within one batch" do
    expression = "ip.ttl == 64 and frame.number != 2 and (frame.number == 1 or frame.time_delta_displayed > 2)"
    frames = [1, 2, 4, 5].map.with_index { |seconds, index| frame(number: index + 1, timestamp_ns: seconds * 1_000_000_000) }
    @documents = [false, true].map do |isolated|
      doc = Vanken::App::Document.new(process_analysis: isolated)
      doc.apply_filter(expression).wait(2)
      doc.ingest(frames, live: true).wait(5)
      doc
    end
    expect(@documents.map(&:error)).to eq([nil, nil])
    expect(@documents.map(&:display_numbers)).to eq([[1, 3], [1, 3]])
    doc = @documents.last
    expect(Vanken::Capture::FilterWorker.call(doc.filter_payload(1, 5, expression: expression))).to eq("matches" => [1, 3])
  end

  it "rechecks a changed filter and mutable context without analyzing the retained batch again" do
    analyzed = Queue.new
    @release = Queue.new
    commands = Queue.new
    release = @release
    allow(Vanken::Capture::AnalyzerProcess).to receive(:new).and_wrap_original do |constructor, *arguments, **options|
      analyzer = constructor.call(*arguments, **options)
      allow(analyzer).to receive(:request).and_wrap_original do |request, value|
        result = request.call(value)
        commands << value[:command]
        if value[:command] == :analyze
          analyzed << true
          release.pop
        end
        result
      end
      analyzer
    end
    @document = Vanken::App::Document.new
    @document.apply_filter("frame.number == 1").wait(2)
    @document.ingest(split_http_frames, live: true)
    Timeout.timeout(5) { analyzed.pop }
    @document.marked << 3
    @document.ignored << 1
    @document.time_references << 2
    expression = 'http.request.method == "GET" and frame.marked == true and frame.ignored == false and frame.time_relative == 1 and frame.time_delta_displayed == 0'
    @document.apply_filter(expression)
    wait_until { @document.progress.nil? }
    release << true
    @document.wait(5)
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([3])
    expect(@document.count).to eq(3)
    expect(@document.stream_frames(0)).to eq([1, 2, 3])
    expect(@document.annotations[3][:analysis_flags]).not_to include("retransmission")
    calls = []
    calls << commands.pop until commands.empty?
    expect(calls.count(:analyze)).to eq(1)
    expect(calls.count(:match)).to eq(1)
    expect(File.size(File.join(@document.store.directory, "annotations.bin"))).to eq(3 * Vanken::Core::AnnotationStore::SIZE)
    expect(Vanken::Capture::FilterWorker.call(@document.filter_payload(1, 4, expression: expression))).to eq("matches" => [3])
  end

  it "preserves a TCP stream, reassembly, and retransmission annotations across the packed batch boundary" do
    first, second, final = split_http_frames
    payload = "padding".b
    ip = [0x45, 0, 28 + payload.bytesize, 1, 0, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
    udp = ["0200000000020200000000010800"].pack("H*") + ip + [1234, 9999, 8 + payload.bytesize, 0].pack("n4") + payload
    frames = [first, second] + Array.new(254) { |index| frame(udp, number: index + 3, timestamp_ns: 2_000_000_000) }
    frames << final.with(number: 257)
    frames << final.with(number: 258)
    @document = Vanken::App::Document.new
    @document.ingest(frames).wait(5)
    expect(@document.error).to be_nil
    expect(@document.count).to eq(258)
    expect(@document.packet_snapshot(257).values("http.request.method")).to eq(["GET"])
    expect(@document.stream_frames(0)).to eq([1, 2, 257, 258])
    expect(@document.annotations[257][:seq_rel]).to eq(3)
    expect(@document.annotations[258][:analysis_flags]).to include("retransmission")
    expression = "tcp.analysis.retransmission and tcp.stream == 0 and tcp.seq_relative == 3"
    @document.apply_filter(expression).wait(2)
    expect(@document.display_numbers).to eq([258])
    expect(Vanken::Capture::FilterWorker.call(@document.filter_payload(1, 259, expression: expression))).to eq("matches" => [258])
  end

  it "keeps the raw predecessor when a historical scan started from an unfiltered display" do
    source = live_source(split_http_frames)
    @document = Vanken::App::Document.new.ingest(source, live: true)
    wait_until { @document.count == 3 }
    @document.scanner = pending_scanner
    expression = "ip.ttl == 64 and frame.time_delta_displayed == 2"
    @document.apply_filter(expression)
    Timeout.timeout(5) { @submitted.pop }
    expect(@document.instance_variable_get(:@filter_context)[:predecessors]).to be_nil
    source.push(frame(number: 4, timestamp_ns: 5_000_000_000))
    source.push(frame(number: 5, timestamp_ns: 7_000_000_000))
    wait_until { @document.count == 5 }
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([4, 5])
  end

  it "rechecks a completed historical context even when the filter generation did not change" do
    analyzed = Queue.new
    @release = Queue.new
    release = @release
    allow(Vanken::Capture::AnalyzerProcess).to receive(:new).and_wrap_original do |constructor, *arguments, **options|
      analyzer = constructor.call(*arguments, **options)
      allow(analyzer).to receive(:request).and_wrap_original do |request, value|
        result = request.call(value)
        if value[:command] == :analyze && value[:first] == 4
          analyzed << [value, result]
          release.pop
        end
        result
      end
      analyzer
    end
    source = live_source(split_http_frames)
    @document = Vanken::App::Document.new.ingest(source, live: true)
    wait_until { @document.count == 3 }
    @document.apply_filter("frame.number != 2")
    wait_until { @document.progress.nil? }
    expect(@document.display_numbers).to eq([1, 3])
    @document.scanner = pending_scanner
    expression = "ip.ttl == 64 and frame.time_delta_displayed == 2"
    @document.apply_filter(expression)
    payload, task = Timeout.timeout(5) { @submitted.pop }
    generation = @document.instance_variable_get(:@generation)
    source.push(frame(number: 4, timestamp_ns: 5_000_000_000))
    source.push(frame(number: 5, timestamp_ns: 7_000_000_000))
    request, batch = Timeout.timeout(5) { analyzed.pop }
    expect(request[:historical_context]).to be(true)
    expect(batch.values_at(:first, :last, :matches)).to eq([4, 5, [4]])
    task.resolve(Vanken::Capture::FilterWorker.call(payload))
    wait_until { @document.progress.nil? }
    expect(@document.instance_variable_get(:@generation)).to eq(generation)
    expect(@document.instance_variable_get(:@filter_context)).to be_nil
    release << true
    wait_until { @document.count == 5 }
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([3, 4, 5])
  end

  it "drains the already received partial batch after canceling ingestion" do
    emitted, stopped = Queue.new, Queue.new
    frames = split_http_frames
    source = Object.new
    source.define_singleton_method(:each) do |&block|
      frames.each(&block)
      emitted << true
      stopped.pop
    end
    source.define_singleton_method(:stop) { stopped << true }
    @document = Vanken::App::Document.new
    @document.apply_filter('http.request.method == "GET"').wait(2)
    @document.ingest(source, live: true)
    Timeout.timeout(5) { emitted.pop }
    @document.cancel.wait(5)
    expect(@document.error).to be_nil
    expect(@document.cancelled?).to be(true)
    expect(@document.store.durable_count).to eq(3)
    expect(@document.count).to eq(3)
    expect(@document.display_numbers).to eq([3])
    expect(@document.stream_frames(0)).to eq([1, 2, 3])
    expect { Process.waitpid(@document.instance_variable_get(:@analyzer).pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  end

  it "stops reception and reaps a failed child without publishing duplicate or malformed records" do
    source = live_source(split_http_frames)
    @document = Vanken::App::Document.new.ingest(source, live: true)
    wait_until { @document.count == 3 }
    pid = @document.instance_variable_get(:@analyzer).pid
    Process.kill("KILL", pid)
    source.push(frame(number: 4))
    @document.wait(5)
    expect(@document.error).to be_a(StandardError)
    expect(@document.cancelled?).to be(true)
    expect(@document.received?).to be(true)
    expect(@document.count).to eq(3)
    expect(@document.display_numbers).to eq([1, 2, 3])
    expect(@document.stream_frames(0)).to eq([1, 2, 3])
    expect(File.size(File.join(@document.store.directory, "annotations.bin"))).to eq(3 * Vanken::Core::AnnotationStore::SIZE)
    expect { Process.waitpid(pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  end
end
