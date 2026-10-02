# frozen_string_literal: true

require "spec_helper"
require "vanken/capture/filter_worker"
require_relative "../support/packets"

RSpec.describe "Consistent analysis configuration" do
  def dns_frame
    dns = [0x1234, 0x0100, 0, 0, 0, 0].pack("n6")
    udp = [51514, 8443, dns.bytesize + 8, 0].pack("n4") + dns
    ip = [0x45, 0, 20 + udp.bytesize, 1, 0, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
    frame(["0200000000020200000000010800"].pack("H*") + ip + udp)
  end

  it "rebuilds columns, details, and worker filters with Decode As while retaining frame bytes" do
    document = Vanken::App::Document.new.ingest([dns_frame]).wait
    expect(document.row(1)[:protocol]).to eq("UDP")
    document.reanalyze(decode_as: ["udp.port==8443,dns"]).wait
    expect(document.store.durable_count).to eq(1)
    expect(document.row(1)[:protocol]).to eq("DNS")
    expect(document.packet(1).layer?("dns")).to be(true)
    payload = document.filter_payload(1, 2, expression: "dns")
    expect(Vanken::Capture::FilterWorker.call(payload)["matches"]).to eq([1])
  ensure
    document&.close
  end

  it "recovers an interrupted spool into a complete unsaved document" do
    store = Vanken::Core::FrameStore.new
    directory = store.directory
    store.append(frame)
    store.flush
    store.close(remove: false)
    File.open(File.join(directory, "frames.idx"), "ab") { |file| file.write("partial") }
    document = Vanken::App::Document.recover(directory).wait
    expect(document.count).to eq(1)
    expect(document.dirty?).to be(true)
    expect(document.row(1)[:protocol]).to eq("TCP")
    expect(document.store.read(1).bytes).to eq(frame.bytes)
  ensure
    document&.close
  end

  it "retains historical displayed-delta semantics when rebuilding in either analyzer" do
    document = nil
    [true, false].each do |process_analysis|
      document = Vanken::App::Document.new(process_analysis: process_analysis).ingest(
        3.times.map { |index| frame(number: index + 1, timestamp_ns: (index + 1) * 1_000_000_000) }).wait
      document.apply_filter("frame.time_delta_displayed > 0").wait
      expect(document.display_numbers).to eq([2, 3])
      document.reanalyze.wait
      expect(document.display_numbers).to eq([2, 3])
      expect(document.error).to be_nil
      expect(document.dirty?).to be(false)
      document.close
    end
  ensure
    document&.close
  end
end
