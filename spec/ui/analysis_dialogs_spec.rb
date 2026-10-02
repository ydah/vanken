# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/application"
require "vanken/ui/analysis_dialogs"
require_relative "../support/packets"

RSpec.describe "Analysis dialogs" do
  before do
    @directory = Dir.mktmpdir
    preferences = Vanken::Config::Preferences.new(directory: @directory)
    preferences.set("layout.width", 1000)
    preferences.set("layout.height", 800)
    @ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
    # Keep the real layout, focus, and scene rendering; assertions do not inspect pixels.
    allow(@ui.window).to receive(:render).and_wrap_original do |original, element, **options|
      original.call(element, **options, present: false)
    end
    @doc = Vanken::App::Document.new(process_analysis: false).ingest([
      frame(tcp_bytes(seq: 100, flags: 2)),
      frame(tcp_bytes(seq: 101, flags: 16, payload: "hello world"), number: 2),
      frame(tcp_bytes(seq: 112, flags: 16, payload: "hello again"), number: 3)
    ]).wait
    @ui.attach_document(@doc)
  end
  after do
    @ui&.close_analysis
    @ui&.close
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  def settle(id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      snapshot = Zaniah::Inspection.snapshot(@ui.window)
      return snapshot if snapshot.find(test_id: id)
      raise "dialog did not settle: #{@ui.dialog_kind}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.001)
    end
  end

  it "renders upstream hierarchy and five-type conversation/endpoint tables, expert groups, and I/O series" do
    @ui.protocol_hierarchy
    expect(settle("vk.stats.hierarchy").find(test_id: "vk.stats.hierarchy")).not_to be_nil
    @ui.conversations
    expect(settle("vk.stats.tabs").find(test_id: "vk.stats.tabs")).not_to be_nil
    @ui.endpoints
    expect(settle("vk.stats.tabs").find(test_id: "vk.stats.tabs")).not_to be_nil
    @ui.expert_info
    expect(settle("vk.expert.table").find(test_id: "vk.expert.table")).not_to be_nil
    @ui.io_graph(expressions: ["", "tcp.port == 80"])
    expect(settle("vk.io.chart").find(test_id: "vk.io.chart")).not_to be_nil
    @ui.close_analysis
    expect(@ui.instance_variable_get(:@statistics_job)).to be_nil
  end

  it "shows direction-colored TCP text, searches successive matches, and exposes full-data export" do
    @ui.follow_tcp_stream(0)
    snapshot = settle("vk.follow.text")
    expect(snapshot.find(test_id: "vk.follow.text")).not_to be_nil
    text = @ui.instance_variable_get(:@follow_text)
    expect(text.text).to eq("hello worldhello again")
    @ui.search_stream("hello")
    expect(text.selection.range).to eq(0...5)
    @ui.search_stream("hello")
    expect(text.selection.range).to eq(11...16)
    stream = @ui.instance_variable_get(:@follow_stream)
    expect(stream.byte_size).to eq(22)
    @ui.export_dissections
    expect(settle("vk.export.save").find(test_id: "vk.export.range")).not_to be_nil
    @ui.file_properties
    expect(settle("vk.properties.sha256").find(test_id: "vk.file_properties")).not_to be_nil
  end

  it "waits for an executing analysis to finish before closing its frame store" do
    entered, release = Queue.new, Queue.new
    @ui.send(:analysis_dialog, :expert_info, "Expert", Zaniah::Div.new)
    @ui.send(:analysis_background, ->(doc, _) { entered << true; release.pop; doc.store.read(1) }) { raise "stale publication" }
    entered.pop
    closer = Thread.new { @ui.close_analysis }
    sleep(0.01)
    expect(closer).to be_alive
    release << true
    expect(closer.join(2)).to eq(closer)
    expect { @ui.app.executor.drain }.not_to raise_error
    expect(@doc.store.read(1).bytes).to eq(frame.bytes)
  end
end
