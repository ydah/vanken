# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../support/packets"

RSpec.describe "Canceling reanalysis without discarding raw packets" do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end

  after do
    @release&.push(true)
    File.write(@release_path, "release") if @release_path
    @document&.close
  end

  def original_document(isolated)
    @frames = 4.times.map { |index| frame(number: index + 1, timestamp_ns: index * 1_000_000_000) }
    @document = Vanken::App::Document.new(process_analysis: isolated).ingest(@frames, live: true).wait(5)
  end

  def preserves_packets_after_cancel
    @document.cancel_reanalysis
    @release&.push(true)
    @document.wait(3)
    expect(@document.count).to be < 4
    expect(@document.complete?).to be(true)
    expect(@document.error).to be_nil
    expect(@document.store.durable_count).to eq(4)
    expect(@document.store.read(4).bytes).to eq(@frames.last.bytes)
    path = File.join(@directory, "retained.pcapng")
    @document.save(path).wait_for_save
    expect(Vanken::Gateway::FileReader.new(path).map(&:bytes)).to eq(@frames.map(&:bytes))
    expect(@document.dirty?).to be(false)
  end

  it "stops an in-process rebuild after the current dissector returns" do
    original_document(false)
    entered, @release = Queue.new, Queue.new
    calls = []
    release = @release
    allow(Vanken::Gateway::Dissector).to receive(:new).and_wrap_original do |constructor, **options|
      dissector = constructor.call(**options)
      allow(dissector).to(receive(:dissect).and_wrap_original do |dissect, item|
        calls << item.number
        if calls.size == 1
          entered << true
          release.pop
        end
        dissect.call(item)
      end)
      dissector
    end
    @document.reanalyze
    Timeout.timeout(5) { entered.pop }
    preserves_packets_after_cancel
    expect(calls).to eq([1])
  end

  it "interrupts a blocked real worker response and reaps the worker" do
    original_document(true)
    marker = File.join(@directory, "worker-entered")
    @release_path = File.join(@directory, "worker-release")
    plugin = File.join(@directory, "pause_worker.rb")
    File.write(plugin, <<~PLUGIN)
      if Process.pid != #{Process.pid}
        ::Vanken::Gateway::Dissector.prepend(Module.new do
          def dissect(frame)
            File.open(#{marker.inspect}, "ab") { |file| file.puts(frame.number) }
            sleep(0.01) until File.exist?(#{@release_path.inspect})
            super(frame)
          end
        end)
      end
    PLUGIN
    @document.reanalyze(plugins: [plugin])
    Timeout.timeout(5) { sleep(0.001) until File.exist?(marker) }
    analyzer = @document.instance_variable_get(:@analyzer)
    preserves_packets_after_cancel
    expect(File.readlines(marker)).to eq(["1\n"])
    expect { Process.waitpid(analyzer.pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  end
end
