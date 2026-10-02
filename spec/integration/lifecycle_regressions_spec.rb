# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "vanken/capture/filter_worker"
require_relative "../support/packets"

RSpec.describe "document lifecycle regressions" do
  def wait_until
    Timeout.timeout(3) { sleep(0.005) until yield }
  end

  after { @document&.close }

  it "allows filters after capture has stopped" do
    @document = Vanken::App::Document.new
    @document.ingest([frame], live: true).wait(2)
    @document.cancel
    @document.apply_filter("tcp.port == 1234").wait(2)
    expect(@document.display_numbers).to eq([])
    expect(@document.filter.expression).to eq("tcp.port == 1234")
  end

  it "drains the final durable frames when reception finishes between checks" do
    @document = Vanken::App::Document.new
    document = @document
    incoming = frame
    first = true
    document.store.define_singleton_method(:durable_count) do
      value = super()
      if first
        first = false
        append(incoming)
        flush
        document.receiving_done
      end
      value
    end
    Vanken::Capture::Analyzer.new(document, Vanken::Gateway::Dissector.new).run
    expect(document.count).to eq(1)
    expect(document.complete?).to be(true)
  end

  it "publishes exactly one annotation record when incremental filtering fails" do
    @document = Vanken::App::Document.new(process_analysis: false)
    attempts = 0
    filter = Object.new
    filter.define_singleton_method(:match?) { |_| attempts += 1; raise "filter failure" if attempts == 1; true }
    @document.instance_variable_set(:@filter, filter)
    @document.instance_variable_set(:@display, [])
    @document.ingest([frame, frame(number: 2)]).wait(2)
    expect(File.size(File.join(@document.store.directory, "annotations.bin"))).to eq(64)
    expect(@document.annotations[2][:tcp_stream]).to be >= 0
  end

  it "evaluates displayed-time filters on incoming packets without recursively locking" do
    @document = Vanken::App::Document.new
    @document.apply_filter("frame.time_delta_displayed >= 0").wait(2)
    @document.ingest([frame, frame(number: 2)]).wait(2)
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([1, 2])
    expect(File.size(File.join(@document.store.directory, "annotations.bin"))).to eq(64)
  end

  it "observes dynamic fields and publishes immutable completion snapshots" do
    @document = Vanken::App::Document.new
    old_names = @document.catalog.names
    @document.ingest([frame(tcp_bytes(flags: 24, payload: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))]).wait(2)
    expect(@document.catalog.lookup("http.request.method")).not_to be_nil
    expect(@document.catalog.names).to include("http.request.method")
    expect(old_names).not_to include("http.request.method")
    expect(@document.catalog.names).to be_frozen
  end

  it "prevents a replaced slow filter from committing stale results" do
    started, release = Queue.new, Queue.new
    scanner = ->(payload) { started << payload["expr"]; release.pop; {"matches" => [1]} }
    @document = Vanken::App::Document.new(scanner: scanner)
    @document.ingest([frame]).wait(2)
    @document.apply_filter("ip.src == 192.0.2.10")
    expect(Timeout.timeout(3) { started.pop }).to eq("ip.src == 192.0.2.10")
    @document.apply_filter("frame.number == 2")
    wait_until { @document.filter&.expression == "frame.number == 2" }
    release << true
    @document.wait(2)
    expect(@document.filter.expression).to eq("frame.number == 2")
    expect(@document.display_numbers).to eq([])
  ensure
    release << true if release
  end

  it "prevents an earlier sort from reintroducing packets removed by a new filter" do
    started, release = Queue.new, Queue.new
    @document = Vanken::App::Document.new
    @document.ingest([frame]).wait(2)
    @document.define_singleton_method(:row) { |number| started << true; release.pop; super(number) }
    @document.sort(:source)
    Timeout.timeout(3) { started.pop }
    @document.apply_filter("frame.number == 2")
    wait_until { @document.filter&.expression == "frame.number == 2" }
    release << true
    @document.wait(2)
    expect(@document.display_numbers).to eq([])
  ensure
    release << true if release
  end

  it "uses all transport fields and embedded layers in fast filtering" do
    @document = Vanken::App::Document.new
    @document.store.append(frame)
    @document.store.flush
    packet = Vanken::Gateway::Dissector.new.dissect(frame)
    tcp = Redhound::Layer.new(:tcp, 0, 0, frame.bytes.bytesize, embedded: true)
    tcp.add(:srcport, "tcp.srcport", 4000, type: :uint16)
    tcp.add(:dstport, "tcp.dstport", 443, type: :uint16)
    udp = Redhound::Layer.new(:udp, 0, 0, frame.bytes.bytesize, embedded: true)
    udp.add(:srcport, "udp.srcport", 555, type: :uint16)
    udp.add(:dstport, "udp.dstport", 666, type: :uint16)
    packet.layers.concat([tcp, udp])
    @document.publish(1, packet)
    expect(@document.view(1).values("tcp.port")).to eq(packet.values("tcp.port"))
    expect(@document.view(1).values("udp.port")).to eq([555, 666])
    expect(@document.view(1).layer?("udp")).to be(true)
    @document.apply_filter("tcp.port == 443 and udp").wait(2)
    expect(@document.display_numbers).to eq([1])
  end

  it "retains reassembled summaries after the row cache is cleared" do
    @document = Vanken::App::Document.new
    @document.store.append(frame)
    @document.store.flush
    packet = Vanken::Gateway::Dissector.new.dissect(frame)
    packet.define_singleton_method(:reassembled?) { true }
    packet.define_singleton_method(:info) { "reassembled GET /complete" }
    @document.publish(1, packet)
    @document.instance_variable_get(:@cache).clear
    expect(@document.row(1)[:info]).to eq("reassembled GET /complete")
  end

  it "keeps newly captured frames dirty when saving an earlier snapshot" do
    started, release = Queue.new, Queue.new
    @document = Vanken::App::Document.new
    @document.ingest([frame], live: true).wait(2)
    allow(Vanken::Gateway::FileWriter).to receive(:open).and_wrap_original do |original, *arguments, **options, &block|
      original.call(*arguments, **options) { |writer| started << true; release.pop; block.call(writer) }
    end
    Dir.mktmpdir do |directory|
      @document.save(File.join(directory, "capture.pcapng"))
      Timeout.timeout(3) { started.pop }
      incoming = frame(number: 2)
      @document.store.append(incoming)
      @document.store.flush
      @document.publish(2, Vanken::Gateway::Dissector.new.dissect(incoming))
      release << true
      @document.wait(2)
      expect(@document.dirty?).to be(true)
    end
  ensure
    release << true if release
  end

  it "flushes partial capture batches on an idle timeout" do
    @document = Vanken::App::Document.new
    source = Object.new
    calls = 0
    document = @document
    incoming = frame
    source.define_singleton_method(:next_frame) do |timeout:|
      calls += 1
      @timeout = timeout
      if calls == 1
        incoming
      elsif calls == 2
        sleep(0.06)
        nil
      else
        @observed = document.store.durable_count
        @eof = true
        nil
      end
    end
    source.define_singleton_method(:eof?) { !!@eof }
    Vanken::Capture::Receiver.new(document, source).run
    expect(source.instance_variable_get(:@observed)).to eq(1)
    expect(source.instance_variable_get(:@timeout)).to be <= 0.05
    expect(document.error).to be_nil
  end

  it "supports repeated close calls" do
    @document = Vanken::App::Document.new
    @document.close
    expect { @document.close }.not_to raise_error
  end

  it "uses current time references and snapshots mutable worker context" do
    @document = Vanken::App::Document.new
    @document.ingest([frame(timestamp_ns: 1_000_000_000), frame(number: 2, timestamp_ns: 2_000_000_000)]).wait(2)
    @document.time_references << 2
    @document.marked << 1
    expect(@document.view(2).values("frame.time_relative")).to eq([0.0])
    payload = @document.filter_payload(1, 3, expression: "ip.src == 192.0.2.10 and frame.marked == true")
    @document.marked.clear
    expect(payload["marked"]).to eq([1])
    expect(File.stat(payload["annotations_json"]).mode & 0o777).to eq(0o600)
    expect(Vanken::Capture::FilterWorker.call(payload)).to eq("matches" => [1])
    payload["expr"] = "ip.src == 192.0.2.10 and frame.time_relative == 0"
    expect(Vanken::Capture::FilterWorker.call(payload)).to eq("matches" => [1, 2])
  end

  it "applies the configured analysis flow limit and state budget" do
    Dir.mktmpdir do |directory|
      preferences = Vanken::Config::Preferences.new(directory: directory)
      preferences.set("analysis.max_flows", 1)
      preferences.set("analysis.max_state_mib", 2)
      @document = Vanken::App::Document.new(preferences: preferences)
      dissector = Vanken::Gateway::Dissector.new
      analyzer = Vanken::Capture::Analyzer.new(@document, dissector)
      analysis = analyzer.instance_variable_get(:@analysis)
      analysis.update(dissector.dissect(frame))
      analysis.update(dissector.dissect(frame(tcp_bytes(port: 443), number: 2)))
      session = analysis.instance_variable_get(:@session)
      expect(session.flows.evicted).to eq(1)
      expect(session.instance_variable_get(:@max_state_bytes)).to eq(2 << 20)
      analysis.close
    end
  end
end
