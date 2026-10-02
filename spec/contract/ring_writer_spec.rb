# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "capture ring files" do
  it "keeps the latest bounded size files with exact packets and private permissions" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "ring.pcapng")
      2.times { |index| File.write(File.join(directory, "ring_#{format('%05d', index)}.pcapng"), "old", mode: "w", perm: 0o644) }
      writer = Vanken::Gateway::FileWriter.open(path, max_bytes: 1, file_count: 2)
      5.times { |index| writer << frame(tcp_bytes(payload: index.to_s), number: index + 1) }
      writer.close
      paths = Dir[File.join(directory, "ring_*.pcapng")]
      expect(paths.size).to eq(2)
      expect(paths.map { |file| File.stat(file).mode & 0o777 }).to eq([0o600, 0o600])
      data = paths.flat_map { |file| Vanken::Gateway::FileReader.new(file).to_a.map(&:bytes) }
      expect(data).to contain_exactly(tcp_bytes(payload: "3"), tcp_bytes(payload: "4"))
    ensure
      writer&.close
    end
  end

  it "cycles time-based files rather than ending capture at the file count" do
    Dir.mktmpdir do |directory|
      clock = 0.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock }
      writer = Vanken::Gateway::FileWriter.open(File.join(directory, "timed.pcapng"), interval: 1, file_count: 2)
      4.times do |index|
        writer << frame(tcp_bytes(payload: index.to_s))
        clock += 1.1
      end
      writer.close
      paths = Dir[File.join(directory, "timed_*.pcapng")]
      expect(paths.size).to eq(2)
      expect(paths.flat_map { |file| Vanken::Gateway::FileReader.new(file).to_a.map(&:bytes) }).to contain_exactly(tcp_bytes(payload: "2"), tcp_bytes(payload: "3"))
    ensure
      writer&.close
    end
  end
end
