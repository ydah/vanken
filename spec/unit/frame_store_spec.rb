# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "objspace"
require_relative "../support/packets"

RSpec.describe "Disk frame storage" do
  it "rejects linked auxiliary analysis files without truncating their targets during recovery" do
    [:symlink, :link].each do |kind|
      Dir.mktmpdir do |outside|
        target = File.join(outside, "valuable")
        File.write(target, "retain this data")
        store = Vanken::Core::FrameStore.new
        store.append(frame)
        store.flush
        directory = store.directory
        store.close(remove: false)
        File.public_send(kind, target, File.join(directory, "summaries.bin"))
        expect { Vanken::App::Document.recover(directory) }.to raise_error(Vanken::FileError, /unsafe session file/)
        expect(File.binread(target)).to eq("retain this data")
        FileUtils.remove_entry_secure(directory)
      end
    end
  end

  it "keeps index memory bounded during capture and recovery while preserving append order" do
    store = Vanken::Core::FrameStore.new
    incoming = frame
    50_000.times { store.append(incoming) }
    store.flush
    memory = ObjectSpace.reachable_objects_from(store).sum { |value| ObjectSpace.memsize_of(value) }
    expect(memory).to be < 65_536
    expect(store.read(50_000).bytes).to eq(incoming.bytes)
    directory = store.directory
    store.close(remove: false)

    restored = Vanken::Core::FrameStore.recover(directory)
    memory = ObjectSpace.reachable_objects_from(restored).sum { |value| ObjectSpace.memsize_of(value) }
    expect(memory).to be < 65_536
    expect(restored.count).to eq(50_000)
    expect(restored.append(incoming)).to eq(50_001)
    expect { restored.read(50_001) }.to raise_error(IndexError)
    restored.flush
    expect(restored.read(50_001).number).to eq(50_001)
  ensure
    restored&.close
    store&.close
  end

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

  it "reads durable records without moving either writer when positional reads are unavailable" do
    store = Vanken::Core::FrameStore.new
    [:@reader, :@index_reader].each do |name|
      allow(store.instance_variable_get(name)).to receive(:respond_to?).with(:pread).and_return(false)
    end
    store.append(frame(timestamp_ns: 1))
    store.flush
    store.append(frame(timestamp_ns: 2))
    expect(store.read(1).timestamp_ns).to eq(1)
    expect { store.read(2) }.to raise_error(IndexError)
    store.append(frame(timestamp_ns: 3))
    store.flush
    expect((1..3).map { |number| store.read(number).timestamp_ns }).to eq([1, 2, 3])
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
      File.open(File.join(directory, "frames.idx"), "ab") do |io|
        io.write([0, 1, 1, 0, 1, 0xffff, 0].pack(Vanken::Core::FrameStore::RECORD))
        io.write("partial")
      end
      File.open(File.join(directory, "frames.bin"), "ab") { |io| io.write("unindexed") }
      restored = Vanken::Core::FrameStore.recover(directory)
      expect(restored.durable_count).to eq(10_000)
      expect(restored.read(10_000).bytes).to eq(tcp_bytes)
      expect(restored.read(10_000).number).to eq(10_000)
      expect(File.size(File.join(directory, "frames.idx"))).to eq(10_000 * 32)
      expect(File.size(File.join(directory, "frames.bin"))).to eq(10_000 * tcp_bytes.bytesize)
      restored.close
    end
  end
end
