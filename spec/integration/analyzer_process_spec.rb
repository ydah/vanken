# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"
require "vanken/capture/analyzer_worker"

RSpec.describe "isolated packet analysis" do
  after { @document&.close }

  it "keeps stateful analysis and summaries in a reaped child without reparsing rows" do
    @document = Vanken::App::Document.new
    first = frame(tcp_bytes(seq: 1, flags: 24, payload: "GET / HTTP/1.1\r\nHost: ex"))
    second = frame(tcp_bytes(seq: 24, flags: 24, payload: "ample.com\r\n\r\n"), number: 2)
    @document.ingest([first, second, first.with(number: 3)]).wait(5)
    expect(@document.error).to be_nil
    analyzer = @document.instance_variable_get(:@analyzer)
    expect(analyzer.pid).not_to eq(Process.pid)
    expect { Process.waitpid(analyzer.pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    expect(@document.annotations[3][:analysis_flags]).to include("retransmission")
    expect(@document.packet_snapshot(2)&.values("http.request.method")).to eq(["GET"])
    expect(@document.catalog.names).to include("http.request.method")
    allow(@document).to receive(:packet).and_raise("rows must use child summaries")
    expect(@document.row(2)[:info]).not_to be_empty
    expect(@document.details(2).flat_map(&:children)).not_to be_empty
    expect(File.size(File.join(@document.store.directory, "annotations.bin"))).to eq(96)
  end

  it "aborts and reaps a waiting worker when a document is closed" do
    incoming = Queue.new
    source = Object.new
    source.define_singleton_method(:each) { |&block| loop { value = incoming.pop; break unless value; block.call(value) } }
    source.define_singleton_method(:stop) { incoming << nil }
    @document = Vanken::App::Document.new
    @document.ingest(source, live: true)
    analyzer = @document.instance_variable_get(:@analyzer)
    sleep(0.005) until analyzer.pid
    @document.close
    expect(@document.error).to be_nil
    expect { Process.waitpid(analyzer.pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  end

  it "retains discovered field types after draining earlier unfiltered batches" do
    @document = Vanken::App::Document.new
    payload = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    @document.store.append(frame(tcp_bytes(seq: 1, flags: 24, payload: payload)))
    @document.store.append(frame(tcp_bytes(seq: 1 + payload.bytesize, flags: 24, payload: payload), number: 2))
    @document.store.flush
    worker = Vanken::Capture::AnalyzerWorker.new(spool: @document.store.directory, verify_checksums: false,
      analysis_options: @document.analysis_options)
    request = @document.analysis_configuration(1, 1).merge(first: 1, last: 1, interfaces: [])
    worker.analyze(request)
    expect(worker.instance_variable_get(:@catalog).lookup("http.request.method")).not_to be_nil
    request = request.merge(first: 2, last: 2, expression: 'http.request.method == "GET"')
    expect(worker.analyze(request)[:matches]).to eq([2])
    expect(worker.instance_variable_get(:@columns).instance_variable_get(:@data)).to be_empty
    expect(worker.instance_variable_get(:@annotations).instance_variable_get(:@data)).to be_empty
  ensure
    worker&.close
  end

  it "closes private pipes when creating the worker fails" do
    allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, "missing Ruby executable")
    @document = Vanken::App::Document.new.ingest([frame]).wait(5)
    analyzer = @document.instance_variable_get(:@analyzer)
    expect(@document.error).to be_a(Errno::ENOENT)
    expect(analyzer.instance_variable_get(:@input)).to be_closed
    expect(analyzer.instance_variable_get(:@output)).to be_closed
  end

  it "finishes document analysis even when stopping the worker raises" do
    @document = Vanken::App::Document.new
    @document.receiving_done
    analyzer = Vanken::Capture::AnalyzerProcess.new(@document)
    allow(Process).to receive(:spawn).and_return(999_999)
    allow(analyzer).to receive(:request).and_return({})
    allow(analyzer).to receive(:shutdown).and_wrap_original do |shutdown|
      shutdown.call
      raise Vanken::Error, "worker failed to stop"
    end
    expect { analyzer.run }.to raise_error(Vanken::Error, "worker failed to stop")
    expect(@document.complete?).to be(true)
    expect(@document.loading?).to be(false)
  end
end
