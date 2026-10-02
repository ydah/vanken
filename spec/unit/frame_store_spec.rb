# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "Disk frame storage" do
  it "publishes only flushed frames, restores metadata, and restricts file access" do
    store = Vanken::Core::FrameStore.new
    original = frame(interface: {"name" => "en0", "linktype" => 1, "snaplen" => 262_144})
    store.append(original)
    expect(store.durable_count).to eq(0)
    expect { store.read(1) }.to raise_error(IndexError)
    store.flush
    expect(store.read(1)).to eq(original)
    expect(File.size(File.join(store.directory, "frames.idx"))).to eq(32)
    expect(File.stat(store.directory).mode & 0o777).to eq(0o700)
    Dir[File.join(store.directory, "*")].each { |file| expect(File.stat(file).mode & 0o777).to eq(0o600) }
    store.close
    expect(File.directory?(store.directory)).to be(false)
  ensure
    store&.close
  end

  it "recovers complete frames after interrupted writes without deserializing Ruby objects" do
    Dir.mktmpdir do |parent|
      store = Vanken::Core::FrameStore.new(parent: parent)
      10_000.times { |i| store.append(frame(number: i + 1)) }
      store.flush
      directory = store.directory
      store.close(remove: false)
      File.open(File.join(directory, "frames.idx"), "ab") { |io| io.write("partial") }
      restored = Vanken::Core::FrameStore.recover(directory)
      expect(restored.durable_count).to eq(10_000)
      expect(restored.read(10_000).bytes).to eq(tcp_bytes)
      expect(restored.read(10_000).number).to eq(10_000)
      restored.close
    end
  end
end
