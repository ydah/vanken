# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Vanken::Gateway::FileReader do
  def capture_bytes(count = 1)
    data = "\x00\xffcapture".b
    header = [0xa1b2c3d4, 2, 4, 0, 0, 65_535, 1].pack("VvvV4")
    record = [1, 123, data.bytesize, data.bytesize + 4].pack("V4") + data
    [header + (record * count), data]
  end

  def await_condition
    Timeout.timeout(2) do
      sleep(0.001) until yield
    end
  end

  it "keeps fragmented headers and packet bodies across consumer deadlines" do
    input, output = IO.pipe
    bytes, data = capture_bytes
    opener = Thread.new { described_class.new(input) }
    output.write(bytes.byteslice(0, 2))
    expect(opener.join(0.02)).to be_nil
    output.write(bytes.byteslice(2, 7))
    expect(opener.join(0.02)).to be_nil
    output.write(bytes.byteslice(9, 15))
    expect(opener.join(1)).to eq(opener)
    reader = opener.value
    expect(reader.next_frame(timeout: 0.02)).to be_nil
    expect(reader.eof?).to be(false)
    output.write(bytes.byteslice(24, 18))
    expect(reader.next_frame(timeout: 0.02)).to be_nil
    expect(reader.eof?).to be(false)
    output.write(bytes.byteslice(42..))
    frame = reader.next_frame(timeout: 1)
    expect(frame.bytes).to eq(data)
    expect(frame.number).to eq(1)
    expect(frame.timestamp_ns).to eq(1_000_123_000)
    expect(frame.original_length).to eq(data.bytesize + 4)
    output.close
    expect(reader.next_frame(timeout: 1)).to be_nil
    expect(reader.eof?).to be(true)
  ensure
    output&.close unless output&.closed?
    opener&.join(1)
    reader ||= opener.value if opener && !opener.alive?
    reader&.close
    input&.close unless input&.closed?
  end

  it "uses public binary IO input and batches underlying reads" do
    input, output = IO.pipe
    bytes, data = capture_bytes(100)
    output.write(bytes)
    output.close
    reads = 0
    binary_input = nil
    read_nonblock = input.method(:read_nonblock)
    allow(input).to receive(:read_nonblock) do |*args, **kwargs|
      reads += 1
      read_nonblock.call(*args, **kwargs)
    end
    allow(Redhound).to receive(:open).and_wrap_original do |original, supplied_input|
      binary_input = supplied_input
      original.call(supplied_input)
    end
    reader = described_class.new(input)
    frames = reader.to_a
    expect(frames.size).to eq(100)
    expect(frames.last.number).to eq(100)
    expect(frames.last.bytes).to eq(data)
    expect(reads).to be <= 3
    expect(binary_input).not_to be_a(IO)
    expect(reader.eof?).to be(true)
    reader.close
    expect(input.closed?).to be(false)
  ensure
    reader&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
  end

  it "keeps regular file paths and StringIO inputs synchronous" do
    bytes, data = capture_bytes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "capture.pcap")
      File.binwrite(path, bytes)
      [path, StringIO.new(bytes)].each do |input|
        before = Thread.list
        reader = described_class.new(input)
        expect(Thread.list - before).to be_empty
        expect(reader.to_a.map(&:bytes)).to eq([data])
        reader.close
        expect(input.closed?).to be(false) if input.is_a?(StringIO)
      ensure
        reader&.close
      end
    end
  end

  it "drains prefetched packets before reporting EOF" do
    input, output = IO.pipe
    bytes, = capture_bytes(3)
    output.write(bytes)
    output.close
    reader = described_class.new(input)
    first = reader.next_frame(timeout: 1)
    await_condition { reader.stats.captured == 3 }
    expect(reader.eof?).to be(false)
    expect([first, *reader.to_a].map(&:number)).to eq([1, 2, 3])
    expect(reader.eof?).to be(true)
  ensure
    reader&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
  end

  it "interrupts an idle or partial record read and reaps its worker without closing caller input" do
    input, output = IO.pipe
    bytes, = capture_bytes
    output.write(bytes.byteslice(0, 24))
    before = Thread.list
    reader = described_class.new(input)
    workers = Thread.list - before
    expect(workers.size).to eq(1)
    expect(reader.next_frame(timeout: 0.02)).to be_nil
    output.write(bytes.byteslice(24, 18))
    expect(reader.next_frame(timeout: 0.02)).to be_nil
    stopper = Thread.new { reader.stop }
    expect(stopper.join(1)).to eq(stopper)
    expect(workers.any?(&:alive?)).to be(false)
    expect(reader.next_frame(timeout: 0)).to be_nil
    expect(reader.eof?).to be(true)
    reader.close
    expect(input.closed?).to be(false)
  ensure
    reader&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
    stopper&.join(1)
  end

  it "reaps a producer blocked by the bounded packet queue" do
    input, output = IO.pipe
    bytes, = capture_bytes(100_000)
    output.write(bytes.byteslice(0, 24))
    reader = described_class.new(input)
    sender = Thread.new do
      output.write(bytes.byteslice(24..))
    rescue IOError, Errno::EPIPE
      nil
    end
    queue = reader.instance_variable_get(:@packets)
    expect(queue).to be_a(SizedQueue)
    await_condition { queue.size == queue.max }
    reader.close
    expect(reader.instance_variable_get(:@pump).alive?).to be(false)
    expect(input.closed?).to be(false)
    expect(reader.eof?).to be(true)
  ensure
    reader&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
    sender&.join(1)
  end

  it "bounds queued payload bytes, resumes on consumption, drains EOF, and wakes on stop" do
    bytes, data = capture_bytes(5)
    stub_const("Vanken::Gateway::FileReader::QUEUED_BYTE_LIMIT", data.bytesize * 2)
    [:drain, :stop].each do |operation|
      input, output = IO.pipe
      output.write(bytes)
      reader = described_class.new(input)
      await_condition { reader.stats.captured == 3 }
      queue = reader.instance_variable_get(:@packets)
      expect(queue.size).to eq(2)
      expect(reader.instance_variable_get(:@queued_bytes)).to eq(data.bytesize * 2)

      if operation == :drain
        first = reader.next_frame(timeout: 1)
        await_condition { reader.stats.captured == 4 }
        expect(queue.size).to eq(2)
        expect(reader.instance_variable_get(:@queued_bytes)).to eq(data.bytesize * 2)
        output.close
        expect([first, *reader.to_a].map(&:number)).to eq([1, 2, 3, 4, 5])
        expect(reader.instance_variable_get(:@queued_bytes)).to eq(0)
        expect(reader.eof?).to be(true)
      else
        closer = Thread.new { reader.close }
        expect(closer.join(1)).to eq(closer)
        expect(reader.instance_variable_get(:@pump).alive?).to be(false)
        expect(input.closed?).to be(false)
        expect(reader.eof?).to be(true)
      end
    ensure
      # Let cleanup finish even if a future stop regression forgets to wake its budget waiter.
      if closer&.alive?
        reader.instance_variable_get(:@budget_mutex).synchronize do
          reader.instance_variable_get(:@budget_available).broadcast
        end
        closer.join(1)
      end
      reader&.close
      input&.close unless input&.closed?
      output&.close unless output&.closed?
    end
  end

  it "maps malformed and truncated input to FileError without leaking workers" do
    input, output = IO.pipe
    output.write("bad!")
    before = Thread.list
    expect { described_class.new(input) }.to raise_error(Vanken::FileError, /magic/)
    expect(Thread.list - before).to be_empty
    expect(input.closed?).to be(false)
    input.close
    output.close

    input, output = IO.pipe
    bytes, = capture_bytes
    output.write(bytes.byteslice(0, 42))
    output.close
    reader = described_class.new(input)
    expect { reader.next_frame(timeout: 1) }.to raise_error(Vanken::FileError, /truncated/)
    reader.close
    expect(reader.instance_variable_get(:@pump).alive?).to be(false)
    expect(input.closed?).to be(false)
  ensure
    reader&.close
    input&.close unless input&.closed?
    output&.close unless output&.closed?
  end
end
