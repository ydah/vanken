# frozen_string_literal: true

require "spec_helper"
require "vanken/capture/filter_worker"
require "zaniah"
require "zaniah/process_pool"
require_relative "../support/packets"

RSpec.describe "Reassembled packet filters" do
  def split_http_frames
    [frame(tcp_bytes(flags: 2), number: 1),
     frame(tcp_bytes(seq: 101, flags: 24, payload: "GE"), number: 2),
     frame(tcp_bytes(seq: 103, flags: 24, payload: "T /split HTTP/1.1\r\nHost: example.test\r\n\r\n"), number: 3)]
  end

  after do
    @document&.close
    @pool&.shutdown
  end

  ["http.request.method == \"GET\"", "http.host == \"example.test\"", "http and frame.number == 3"].each do |expression|
    it "keeps incremental and direct matches identical for #{expression}" do
      @document = Vanken::App::Document.new
      @document.apply_filter(expression).wait(2)
      @document.ingest(split_http_frames).wait(2)
      expect(@document.display_numbers).to eq([3])
      expect(@document.details(3).flat_map(&:descendants).map(&:field)).to include("http.request.method")
      @document.apply_filter(expression).wait(2)
      expect(@document.error).to be_nil
      expect(@document.display_numbers).to eq([3])
    end
  end

  it "reads the same persisted values through a named process pool worker" do
    @pool = Zaniah::ProcessPool.new(workers: 1, handler: "Vanken::Capture::FilterWorker",
      requires: [File.expand_path("../../lib/vanken/capture/filter_worker.rb", __dir__)],
      load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
    @document = Vanken::App::Document.new(scanner: ->(payload) { @pool.submit(payload) })
    @document.ingest(split_http_frames).wait(2)
    @document.apply_filter('http.request.method == "GET" and http.host == "example.test"').wait(5)
    expect(@document.error).to be_nil
    expect(@document.display_numbers).to eq([3])
  end

  it "round trips repeated binary fields and their declared types without changing encodings" do
    dissector = Vanken::Gateway::Dissector.new
    analysis = Vanken::Gateway::Analysis.new(registry: dissector.registry)
    packets = split_http_frames.map { |item| dissector.dissect(item).tap { |packet| analysis.update(packet) } }
    packet = packets.last
    packet.layers.last.add(:first_bytes, "test.bytes", "\x00\xFF".b, type: :bytes)
    packet.layers.last.add(:second_bytes, "test.bytes", "\x80\xFE".b, type: :bytes)
    packet.layers.last.add(:false_flag, "test.flag", false, type: :boolean)
    snapshot = Vanken::Gateway::PacketSnapshot.from_packet(packet)
    restored = Vanken::Gateway::PacketSnapshot.from_h(JSON.parse(JSON.generate(snapshot.to_h)))
    expect(restored.values("test.bytes")).to eq(packet.values("test.bytes"))
    expect(restored.values("test.bytes").map(&:encoding)).to eq([Encoding::BINARY, Encoding::BINARY])
    expect(restored.field_type("test.bytes")).to eq(:bytes)
    expect(restored.values("test.flag")).to eq([false])
    expect(restored.layer?("http")).to be(true)
    expect(restored.values("ip.addr")).to eq(packet.values("ip.addr"))
  ensure
    analysis&.close
  end

  it "uses persisted repeated binary values in direct and read-only process filtering" do
    @pool = Zaniah::ProcessPool.new(workers: 1, handler: "Vanken::Capture::FilterWorker",
      requires: [File.expand_path("../../lib/vanken/capture/filter_worker.rb", __dir__)],
      load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
    @document = Vanken::App::Document.new
    dissector = Vanken::Gateway::Dissector.new
    analysis = Vanken::Gateway::Analysis.new(registry: dissector.registry)
    split_http_frames.each do |item|
      @document.store.append(item)
      @document.store.flush
      packet = dissector.dissect(item)
      analysis.update(packet)
      if item.number == 3
        packet.layers.last.add(:first_bytes, "test.bytes", "\x00\xFF".b, type: :bytes)
        packet.layers.last.add(:second_bytes, "test.bytes", "\x80\xFE".b, type: :bytes)
      end
      @document.publish(item.number, packet)
    end
    @document.instance_variable_get(:@cache).clear
    expression = "test.bytes contains 0xff"
    @document.apply_filter(expression).wait(2)
    expect(@document.display_numbers).to eq([3])
    payload = @document.filter_payload(1, 4, expression: expression)
    files = Dir.glob(File.join(@document.store.directory, "*"))
    before = files.to_h { |path| [path, [File.binread(path), File.stat(path).mtime, File.stat(path).mode]] }
    expect(@pool.submit(payload).await(timeout: 5)).to eq("matches" => [3])
    after = files.to_h { |path| [path, [File.binread(path), File.stat(path).mtime, File.stat(path).mode]] }
    expect(after).to eq(before)
  ensure
    analysis&.close
  end

  it "marks rebuilt IPv4 transport layers as reassembled so virtual offsets cannot highlight original bytes" do
    udp = [51514, 9999, 32, 0].pack("nnnn") + "ABCDEFGHIJKLMNOPQRSTUVWX"
    frames = [udp.byteslice(0, 16), udp.byteslice(16, 16)].each_with_index.map do |part, index|
      ethernet = ["0200000000020200000000010800"].pack("H*")
      ip = [0x45, 0, 20 + part.bytesize, 33, index.zero? ? 0x2000 : 2, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
      frame(ethernet + ip + part, number: index + 1)
    end
    @document = Vanken::App::Document.new.ingest(frames).wait(2)
    nodes = @document.details(2)
    source_port = nodes.flat_map(&:descendants).find { |item| item.field == "udp.srcport" }
    expect(source_port.source).to eq(:reassembled)
    expect(nodes.find { |item| item.id == "udp" }.source).to eq(:reassembled)
    expect(nodes.find { |item| item.id == "ipv4" }.source).to eq(:frame)
    expect(nodes.find { |item| item.id == "eth" }.source).to eq(:frame)
    expect(@document.view(2).values("udp.srcport")).to eq([51514])
  end
end
