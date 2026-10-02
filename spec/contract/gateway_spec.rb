# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "Packet analysis contracts" do
  it "isolates packet decoding, transport columns, safe fields, and stable detail IDs" do
    packet = Vanken::Gateway::Dissector.new.dissect(frame)
    expect(packet.values("ip.src")).to eq(["192.0.2.10"])
    expect(packet.layer?("ip")).to be(true)
    expect(packet.layer?("tcp")).to be(true)
    expect(packet.columns.slice(:source, :destination, :protocol, :src_port, :dst_port)).to eq(
      source: "192.0.2.10", destination: "198.51.100.5", protocol: "TCP", src_port: 51514, dst_port: 80)
    tree = Vanken::Gateway::DetailBuilder.new.build(packet)
    ttl = tree.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
    expect(ttl.id).to eq("ipv4/ip.ttl")
    expect(ttl.offset).to eq(22)
    expect(ttl.length).to eq(1)
    expect(ttl.filter).to eq("ip.ttl == 64")
  end

  it "retains stream annotations from ordered stateful analysis" do
    analysis = Vanken::Gateway::Analysis.new
    first = Vanken::Gateway::Dissector.new.dissect(frame)
    analysis.update(first)
    expect(first.values("tcp.stream")).to eq([0])
    expect(first.annotations[:tcp_stream]).to eq(0)
    expect(Vanken::Gateway::Severity.normalize(:warn)).to eq(:warning)
    expect(Vanken::Gateway::FieldCatalog.new.lookup("tcp.srcport")[:type]).not_to be_nil
    analysis.close
  end

  %w[pcap pcapng].each do |format|
    it "round trips #{format} bytes and nanosecond timestamps with private output permissions" do
      Dir.mktmpdir do |directory|
        path = File.join(directory, "capture.#{format}")
        write_capture(path)
        reader = Vanken::Gateway::FileReader.new(path)
        expect(reader.next_frame.to_h.reject { |key, _| key == :interface }).to eq(frame.to_h.reject { |key, _| key == :interface })
        expect(reader.next_frame).to be_nil
        expect(reader.eof?).to be(true)
        reader.close
        expect(File.stat(path).mode & 0o777).to eq(0o600)
      end
    end
  end

  it "preserves pcapng interface metadata and rejects mixed link types for pcap" do
    Dir.mktmpdir do |directory|
      original = frame(interface: {"name" => "en0", "description" => "Ethernet", "linktype" => 1, "snaplen" => 262_144})
      path = write_capture(File.join(directory, "capture.pcapng"), [original])
      reader = Vanken::Gateway::FileReader.new(path)
      restored = reader.next_frame
      expect(restored.bytes).to eq(original.bytes)
      expect(restored.interface["name"]).to eq("en0")
      reader.close
      expect do
        write_capture(File.join(directory, "mixed.pcap"), [frame, frame("\x45".b, number: 2, linktype: 101)])
      end.to raise_error(Vanken::FileError)
    end
  end
end
