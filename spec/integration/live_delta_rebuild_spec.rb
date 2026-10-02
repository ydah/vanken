# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "zaniah"
require "vanken/capture/filter_worker"
require_relative "../support/packets"

RSpec.describe "Live displayed-delta history during reanalysis" do
  def dns_frame(number)
    dns = [0x1234, 0x0100, 0, 0, 0, 0].pack("n6")
    udp = [51514, 8443, dns.bytesize + 8, 0].pack("n4") + dns
    ip = [0x45, 0, 20 + udp.bytesize, 1, 0, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
    frame(["0200000000020200000000010800"].pack("H*") + ip + udp,
      number: number, timestamp_ns: (number - 1) * 1_000_000_000)
  end

  def wait_until
    Timeout.timeout(5) { sleep(0.001) until yield }
  end

  def live_source
    incoming = Queue.new
    stopped = false
    source = Object.new
    source.define_singleton_method(:push) { |item| incoming << item }
    source.define_singleton_method(:next_frame) do |timeout:|
      incoming.pop(true)
    rescue ThreadError
      sleep(timeout) unless stopped
      nil
    end
    source.define_singleton_method(:eof?) { stopped && incoming.empty? }
    source.define_singleton_method(:stop) { stopped = true }
    source
  end

  def live_document(isolated, expression)
    source = live_source
    [1, 2].each { |number| source.push(dns_frame(number)) }
    @document = Vanken::App::Document.new(process_analysis: isolated).ingest(source, live: true)
    wait_until { @document.count == 2 }
    @document.apply_filter(expression)
    wait_until { @document.progress.nil? }
    [3, 4, 5].each { |number| source.push(dns_frame(number)) }
    wait_until { @document.count == 5 }
    source.stop
    @document.wait(5)
    expect(@document.error).to be_nil
    @document
  end

  after { @document&.close }

  [false, true].each do |isolated|
    context "with #{isolated ? 'isolated' : 'in-process'} analysis" do
      it "retains each arrival's predecessor through an unchanged rebuild and Decode As round trips" do
        doc = live_document(isolated, "frame.number == 1 or (not dns and frame.time_delta_displayed >= 2)")
        expect(doc.display_numbers).to eq([1, 3, 5])
        doc.reanalyze.wait(5)
        expect(doc.display_numbers).to eq([1, 3, 5])
        doc.reanalyze(decode_as: ["udp.port==8443,dns"]).wait(5)
        expect(doc.display_numbers).to eq([1])
        doc.reanalyze(decode_as: []).wait(5)
        expect(doc.display_numbers).to eq([1, 3, 5])
        expect(doc.error).to be_nil
      end

      it "retains the historical context used by arrivals before a pending scan finishes" do
        source = live_source
        [1, 2].each { |number| source.push(dns_frame(number)) }
        doc = @document = Vanken::App::Document.new(process_analysis: isolated).ingest(source, live: true)
        wait_until { doc.count == 2 }
        doc.apply_filter("frame.number == 1")
        wait_until { doc.progress.nil? }
        submitted = Queue.new
        doc.scanner = ->(payload) { Zaniah::Task.new.tap { |task| submitted << [payload, task] } }
        doc.apply_filter("ip.ttl == 64 and (frame.number == 1 or frame.time_delta_displayed >= 2)")
        payload, task = Timeout.timeout(5) { submitted.pop }
        [3, 4, 5].each { |number| source.push(dns_frame(number)) }
        wait_until { doc.count == 5 }
        task.resolve(Vanken::Capture::FilterWorker.call(payload))
        wait_until { doc.progress.nil? }
        source.stop
        doc.wait(5)
        expect(doc.display_numbers).to eq([1, 3, 4, 5])
        doc.reanalyze.wait(5)
        expect(doc.display_numbers).to eq([1, 3, 4, 5])
        expect(doc.error).to be_nil
      end

      it "keeps compact tail history out of IPC and resets it when the filter changes" do
        doc = live_document(isolated, "frame.number == 1 or frame.time_delta_displayed >= 2")
        expect(doc.instance_variable_get(:@filter_live_predecessors).bytesize).to eq(3 * 8)
        entered, release = Queue.new, Queue.new
        paused = false
        analyzer_class = isolated ? Vanken::Capture::AnalyzerProcess : Vanken::Capture::Analyzer
        allow(analyzer_class).to receive(:new).and_wrap_original do |constructor, *arguments, **options|
          analyzer = constructor.call(*arguments, **options)
          unless paused
            paused = true
            allow(analyzer).to(receive(:run).and_wrap_original { |run| entered << true; release.pop; run.call })
          end
          analyzer
        end
        begin
          doc.reanalyze
          Timeout.timeout(5) { entered.pop }
          configuration = doc.analysis_configuration(3, 5)
          expect(configuration[:snapshot][:predecessors]).to eq(3 => 1, 4 => 3, 5 => 3)
          expect(configuration[:snapshot]).not_to have_key(:live_predecessors)
          expect { doc.analysis_configuration(1, 257) }.to raise_error(Vanken::Error, "invalid analysis range")
        ensure
          release << true
        end
        doc.wait(5)
        doc.apply_filter("frame.number >= 1").wait(5)
        expect(doc.instance_variable_get(:@filter_live_predecessors)).to be_nil
        doc.apply_filter("frame.number == 1 or frame.time_delta_displayed >= 2").wait(5)
        expect(doc.instance_variable_get(:@filter_live_predecessors)).to be_empty
        expect(doc.display_numbers).to eq([1])
        doc.reanalyze.wait(5)
        expect(doc.display_numbers).to eq([1])
        doc.apply_filter("").wait(5)
        expect(doc.instance_variable_get(:@filter_live_predecessors)).to be_nil
        doc.reanalyze.wait(5)
        expect(doc.display_numbers).to eq([1, 2, 3, 4, 5])
      end
    end
  end
end
