# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "timeout"
require_relative "../support/packets"

RSpec.describe "Capture documents" do
  it "waits for an overlapping close and removes the capture session only once" do
    document = Vanken::App::Document.new(process_analysis: false).ingest([frame]).wait
    directory = document.store.directory
    entered, release = Queue.new, Queue.new
    allow(document.store).to receive(:close).and_wrap_original do |original|
      entered << true
      release.pop
      original.call
    end
    first = Thread.new { document.close }
    entered.pop
    second = Thread.new { document.close }
    Timeout.timeout(1) { Thread.pass until second.status == "sleep" }
    expect(entered.size).to eq(0), "the second close must wait for the first cleanup"
    release << true
    expect(first.value).to eq(document)
    expect(second.value).to eq(document)
    expect(document.store).to have_received(:close).once
    expect(File.exist?(directory)).to be(false)
  ensure
    2.times { release << true } if release
    [first, second].compact.each { |thread| thread.join rescue nil }
    document&.close
  end

  it "loads through separate receiving and analysis stages and exposes lazy rows and details" do
    Dir.mktmpdir do |directory|
      path = write_capture(File.join(directory, "input.pcap"), [frame, frame(tcp_bytes(seq: 101, flags: 24, payload: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"), number: 2)])
      document = Vanken::App::Document.new
      document.open(path).wait
      expect(document.error).to be_nil
      expect(document.count).to eq(2)
      expect(document.row(1)[:source]).to eq("192.0.2.10")
      expect(document.row(2)[:protocol]).to eq("HTTP")
      expect(document.details(2)).not_to be_empty
      expect(document.stream_frames(0)).to eq([1, 2])
      document.apply_filter("tcp.port == 80 && frame.len > 54").wait
      expect(document.display_numbers).to eq([2])
      document.sort(:length, :desc).wait
      expect(document.display_numbers).to eq([2])
      document.apply_filter("").wait
      document.sort(:length, :desc).wait
      expect(document.display_numbers).to eq([2, 1])
      output = File.join(directory, "saved.pcapng")
      document.save(output).wait
      reader = Vanken::Gateway::FileReader.new(output)
      expect(reader.map(&:bytes)).to eq([frame.bytes, frame(tcp_bytes(seq: 101, flags: 24, payload: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")).bytes])
      reader.close
      document.close
    end
  end

  it "keeps the existing destination intact when saving fails" do
    Dir.mktmpdir do |directory|
      document = Vanken::App::Document.new
      document.ingest([frame, frame("\x45".b, number: 2, linktype: 101)]).wait
      path = File.join(directory, "important.pcap")
      File.write(path, "original")
      document.save(path, format: :pcap).wait
      expect(document.error).to be_a(Vanken::FileError)
      expect(File.read(path)).to eq("original")
      document.close
    end
  end

  it "cancels and cleans up receiving and analysis threads" do
    document = Vanken::App::Document.new
    source = Enumerator.new { |out| loop { out << frame } }
    document.ingest(source)
    document.cancel
    expect(document.wait(1)).to eq(document)
    directory = document.store.directory
    document.close
    expect(File.exist?(directory)).to be(false)
  end
end
