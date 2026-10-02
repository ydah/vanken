# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "Disk frame storage" do
  it "stores every direction and rejects an unknown direction without writing another frame" do
    store = Vanken::Core::FrameStore.new
    [nil, :in, :out].each { |direction| store.append(frame.with(direction: direction)) }
    expect { store.append(frame.with(direction: :unknown)) }.to raise_error(KeyError)
    store.flush
    expect(store.durable_count).to eq(3)
    expect((1..3).map { |number| store.read(number).direction }).to eq([nil, :in, :out])
  ensure
    store&.close
  end

  it "appends frames without allocating a fresh direction lookup table" do
    store = Vanken::Core::FrameStore.new
    incoming = frame
    store.append(incoming)
    before = GC.stat(:total_allocated_objects)
    1_000.times { store.append(incoming) }
    allocations = GC.stat(:total_allocated_objects) - before
    expect(allocations).to be < 7_000
  ensure
    store&.close
  end

  it "preserves signed nanosecond boundaries and rejects values outside the index format" do
    store = Vanken::Core::FrameStore.new
    minimum, maximum = -(1 << 63), (1 << 63) - 1
    store.append(frame(timestamp_ns: minimum))
    store.append(frame(timestamp_ns: maximum))
    expect { store.append(frame(timestamp_ns: minimum - 1)) }.to raise_error(ArgumentError, "invalid frame metadata")
    expect { store.append(frame(timestamp_ns: maximum + 1)) }.to raise_error(ArgumentError, "invalid frame metadata")
    store.flush
    expect(store.durable_count).to eq(2)
    expect(store.read(1).timestamp_ns).to eq(minimum)
    expect(store.read(2).timestamp_ns).to eq(maximum)
  ensure
    store&.close
  end

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
