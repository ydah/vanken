# frozen_string_literal: true

require "spec_helper"
require "vanken/gateway/display_capture_filter"
require "vanken/capture/filter_worker"
require_relative "../support/packets"

RSpec.describe Vanken::Gateway::DisplayCaptureFilter do
  it "matches VDF address, transport, set, and boolean predicates without dissecting eligible bytes" do
    frames = [frame(tcp_bytes(port: 80)), frame(tcp_bytes(port: 443))]
    expressions = ["ip.addr == 192.0.2.10 && tcp.port == 443", "ip.src == 192.0.2.0/24",
      "tcp.dstport in {80 443}", "!(ip.dst == 198.51.100.5) || tcp.port == 80", "udp.port != 53"]
    expressions.each do |expression|
      filter = described_class.new(expression)
      program = Vanken::Core::DisplayFilter.compile(expression)
      frames.each do |item|
        expect(filter.match(item)).to eq(program.match?(Vanken::Gateway::Dissector.new.dissect(item)))
      end
    end
  end

  it "falls back for unsupported fields, truncated bytes, fragments, tunnels, and unknown link types" do
    expect(described_class.new("http.request.method == \"GET\"").expression).to be_nil
    filter = described_class.new("tcp.port == 80")
    original = frame
    expect(filter.match(original.with(bytes: original.bytes.byteslice(0, 40)))).to be_nil
    fragment = original.bytes.dup
    fragment[20, 2] = [0x2000].pack("n")
    expect(filter.match(frame(fragment))).to be_nil
    expect(filter.match(original.with(linktype: 101))).to be_nil
  end

  it "uses cBPF in the real filter worker while retaining ordinary VDF fallback" do
    document = Vanken::App::Document.new.ingest([frame, frame(tcp_bytes(port: 443), number: 2)]).wait
    expect_any_instance_of(Vanken::Gateway::Dissector).not_to receive(:dissect)
    payload = document.filter_payload(1, 3, expression: "ip.addr == 192.0.2.10 && tcp.port == 443")
    expect(Vanken::Capture::FilterWorker.call(payload)["matches"]).to eq([2])
  ensure
    document&.close
  end

  it "uses VDF for Decode As tunnels on a custom port so embedded values stay searchable" do
    payload = [0x08000000, 0].pack("N2") + tcp_bytes(port: 80)
    udp = [51514, 8443, payload.bytesize + 8, 0].pack("n4") + payload
    ip = [0x45, 0, 20 + udp.bytesize, 1, 0, 64, 17, 0, 0xcb007101, 0xcb007102].pack("CCnnnCCnNN")
    item = frame(["0200000000020200000000010800"].pack("H*") + ip + udp)
    document = Vanken::App::Document.new(decode_as: ["udp.port==8443,vxlan"]).ingest([item]).wait
    expect(document.error).to be_nil
    expression = "ip.addr == 192.0.2.10 && tcp.port == 80"
    expect(Vanken::Core::DisplayFilter.compile(expression).match?(document.view(1))).to be(true)
    expect(Vanken::Capture::FilterWorker.call(document.filter_payload(1, 2, expression: expression))["matches"]).to eq([1])
  ensure
    document&.close
  end
end
