# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"
require_relative "../../lib/vanken/gateway/stream"

RSpec.describe Vanken::Gateway::Stream do
  def reverse_tcp(seq:, payload:, flags: 16)
    bytes = tcp_bytes(seq: seq, payload: payload, flags: flags).dup
    bytes[6, 6], bytes[0, 6] = bytes[0, 6], bytes[6, 6]
    bytes[26, 4], bytes[30, 4] = bytes[30, 4], bytes[26, 4]
    bytes[34, 2], bytes[36, 2] = bytes[36, 2], bytes[34, 2]
    bytes
  end

  def document(frames)
    doc = Vanken::App::Document.new(process_analysis: false)
    dissector = Vanken::Gateway::Dissector.new
    analysis = Vanken::Gateway::Analysis.new
    frames.each_with_index do |bytes, index|
      value = frame(bytes, number: index + 1)
      doc.store.append(value)
      doc.store.flush
      packet = dissector.dissect(value)
      analysis.update(packet)
      doc.publish(value.number, packet)
    end
    analysis.close
    doc
  end

  it "reorders each direction, preserves first arrivals on overlap, and shows missing bytes" do
    doc = document([tcp_bytes(seq: 100, flags: 2), reverse_tcp(seq: 500, payload: "", flags: 18),
      tcp_bytes(seq: 104, flags: 16, payload: "DEF"), reverse_tcp(seq: 501, payload: "reply"),
      tcp_bytes(seq: 101, flags: 16, payload: "abcXYZ"), tcp_bytes(seq: 109, flags: 16, payload: "tail")])
    stream = described_class.new(doc, 0)
    expect(stream.preview(format: :ascii, direction: 0).map(&:text).join).to eq("abcDEF[2 bytes missing]tail")
    expect(stream.preview(format: :ascii, direction: 1).map(&:text).join).to eq("reply")
    expect(stream.nodes).to eq(["192.0.2.10:51514", "198.51.100.5:80"])
    expect(stream.preview(format: :hex, direction: 0).map(&:text).join).to include("61 62 63", "44 45 46")
    expect(stream.preview(format: :ascii, direction: 0, limit: 3).map(&:text).join).to eq("abc")
  ensure
    doc&.close
  end

  it "limits displayed bytes without truncating saved raw data and uses private atomic output" do
    doc = document([tcp_bytes(seq: 100, flags: 2), tcp_bytes(seq: 101, flags: 16, payload: "a\x00b\xffcdef")])
    stream = described_class.new(doc, 0)
    expect(stream.preview(format: :ascii, limit: 4).map(&:text).join).to eq("a\\x00b\\xff")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "stream.bin")
      stream.save(path, format: :raw)
      expect(File.binread(path)).to eq("a\x00b\xffcdef".b)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end
    expect { stream.preview(format: :unknown) }.to raise_error(ArgumentError)
  ensure
    doc&.close
  end

  it "unwraps mid-capture relative positions and TCP sequence wraparound" do
    doc = document([tcp_bytes(seq: 101, flags: 16, payload: "bcd"), tcp_bytes(seq: 100, flags: 16, payload: "a")])
    expect(doc.annotations[2][:seq_rel]).to eq(0xffff_ffff)
    expect(described_class.new(doc, 0).preview(direction: 0).map(&:text).join).to eq("abcd")
    doc.close
    doc = document([tcp_bytes(seq: 0xffff_fffd, flags: 2), tcp_bytes(seq: 0xffff_fffe, flags: 16, payload: "ab"),
      tcp_bytes(seq: 0, flags: 16, payload: "cd")])
    expect(described_class.new(doc, 0).preview(direction: 0).map(&:text).join).to eq("abcd")
  ensure
    doc&.close
  end
end
