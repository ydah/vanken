# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"

RSpec.describe "display-filter process worker" do
  before { require "vanken/capture/filter_worker" }

  def worker_session
    store = Vanken::Core::FrameStore.new
    annotations = Vanken::Core::AnnotationStore.new(store.directory)
    3.times do |index|
      number = index + 1
      store.append(frame(tcp_bytes(seq: 100 + index, flags: index == 1 ? 16 : 2), number: number,
                         timestamp_ns: number * 1_000_000_000, interface: {"name" => "test0", "linktype" => 1}))
      annotations.append(number, tcp_stream: 7, seq_rel: index, ack_rel: -1,
        analysis_flags: number == 2 ? ["retransmission"] : [], expert_max: number == 2 ? 2 : 0,
        expert_items: [], extra: {})
    end
    store.flush
    annotations.flush
    yield store
  ensure
    annotations&.close
    store&.close
  end

  def worker_payload(store, expression, **extra)
    {"spool" => store.directory, "expr" => expression, "from" => 1, "to" => 4,
     "decode_as" => [], "plugins" => []}.merge(extra.transform_keys(&:to_s))
  end

  it "reads original frame numbers and applies half-open chunk bounds" do
    worker_session do |store|
      result = Vanken::Capture::FilterWorker.call(worker_payload(store, "ip.src == 192.0.2.10", from: 2, to: 4))
      expect(result).to eq("matches" => [2, 3])
    end
  end

  it "uses persisted stream and analysis flags rather than starting a new analysis session" do
    worker_session do |store|
      expressions = {"tcp.stream == 7" => [1, 2, 3], "tcp.analysis.retransmission" => [2],
                     "tcp.analysis.flags" => [2], "tcp.seq_relative == 2" => [3],
                     "tcp.stream == 7 and ip.src == 192.0.2.10" => [1, 2, 3]}
      expressions.each do |expression, expected|
        expect(Vanken::Capture::FilterWorker.call(worker_payload(store, expression))).to eq("matches" => expected)
      end
    end
  end

  it "reads sparse diagnostic and dynamic analysis values" do
    worker_session do |store|
      path = File.join(store.directory, "annotations.json")
      File.write(path, JSON.generate("experts" => {"2" => [{"severity" => "warning", "code" => "retransmission"}]},
        "extras" => {"3" => {"tcp.analysis.custom_flag" => true}}))
      expect(Vanken::Capture::FilterWorker.call(worker_payload(store, 'expert.code == "retransmission"'))).to eq("matches" => [2])
      expect(Vanken::Capture::FilterWorker.call(worker_payload(store, "expert.severity >= warning"))).to eq("matches" => [2])
      expect(Vanken::Capture::FilterWorker.call(worker_payload(store, "tcp.analysis.custom_flag"))).to eq("matches" => [3])
    end
  end

  it "reads marks, interface metadata, and time context supplied by the document" do
    worker_session do |store|
      context = {marked: [2], ignored: [3], time_reference_ns: 2_000_000_000,
                 displayed_predecessors: {"3" => 1}}
      expressions = {"frame.marked == true" => [2], "frame.ignored == true" => [3],
                     'frame.interface_name == "test0"' => [1, 2, 3],
                     "frame.time_relative == 0" => [2], "frame.time_delta == 1" => [2, 3],
                     "frame.time_delta_displayed == 2" => [3]}
      expressions.each do |expression, expected|
        result = Vanken::Capture::FilterWorker.call(worker_payload(store, expression, **context))
        expect(result).to eq("matches" => expected)
      end
    end
  end

  it "leaves every spool file and permission unchanged" do
    worker_session do |store|
      paths = [store.directory, *Dir[File.join(store.directory, "*")]]
      snapshot = paths.to_h { |path| [path, [File.stat(path).mode, File.stat(path).mtime, File.file?(path) ? File.binread(path) : nil]] }
      2.times { Vanken::Capture::FilterWorker.call(worker_payload(store, "tcp.stream == 7 and tcp")) }
      actual = paths.to_h { |path| [path, [File.stat(path).mode, File.stat(path).mtime, File.file?(path) ? File.binread(path) : nil]] }
      expect(actual).to eq(snapshot)
      expect(Dir[File.join(store.directory, "*")]).to match_array(paths.drop(1))
    end
  end

  [{from: 0}, {to: 5}, {from: 3, to: 2}, {from: "1"}, {decode_as: "tcp.port==80,http"}].each do |arguments|
    it "rejects invalid worker arguments #{arguments}" do
      worker_session do |store|
        expect { Vanken::Capture::FilterWorker.call(worker_payload(store, "tcp", **arguments)) }.to raise_error(ArgumentError)
      end
    end
  end

  it "fails on truncated persisted annotations" do
    worker_session do |store|
      File.truncate(File.join(store.directory, "annotations.bin"), 33)
      expect { Vanken::Capture::FilterWorker.call(worker_payload(store, "tcp.stream == 7")) }.to raise_error(IOError)
    end
  end

  it "reads exact offsets and rejects truncation on an IO without pread" do
    io = Class.new do
      def initialize = @io = StringIO.new("abcdef")
      def seek(offset) = @io.seek(offset)
      def read(length) = @io.read(length)
    end.new
    reader = Vanken::Capture::FilterWorker::Reader.allocate
    expect(io).not_to respond_to(:pread)
    expect(reader.send(:read_exact, io, 3, 2)).to eq("cde")
    expect(reader.send(:read_exact, io, 0, 99)).to eq("".b)
    expect { reader.send(:read_exact, io, 2, 5) }.to raise_error(IOError, /truncated/)
    expect { reader.send(:read_exact, io, 1, 99) }.to raise_error(IOError, /truncated/)
  end

  it "runs as a named process handler with plain JSON arguments" do
    require "zaniah"
    worker_session do |store|
      pool = Zaniah::ProcessPool.new(workers: 1, handler: "Vanken::Capture::FilterWorker",
        requires: [File.expand_path("../../lib/vanken/capture/filter_worker.rb", __dir__)],
        load_paths: $LOAD_PATH.select { |path| File.directory?(path) })
      result = pool.submit(worker_payload(store, "tcp.stream == 7 and ip.addr == 192.0.2.10")).await(timeout: 10)
      expect(result).to eq("matches" => [1, 2, 3])
    ensure
      pool&.shutdown
    end
  end
end
