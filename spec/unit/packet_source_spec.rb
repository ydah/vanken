# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/packet_source"
require_relative "../support/packets"

RSpec.describe Vanken::UI::PacketSource do
  class RowExecutor
    def initialize = (@background, @posted = [], [])
    def background(&block) = @background << block
    def post(&block) = @posted << block
    def finish
      jobs, @background = @background, []
      Thread.new { jobs.each(&:call) }.join
      posts, @posted = @posted, []
      posts.each(&:call)
    end
  end

  before do
    @document = Vanken::App::Document.new.ingest([frame, frame(number: 2, timestamp_ns: 1_700_000_000_124_456_789)]).wait
    @executor = RowExecutor.new
    @settings = {"packet_list.time_format" => "relative", "packet_list.time_precision" => "micro", "packet_list.row_cache_rows" => 20_000}
    preferences = double(get: nil)
    allow(preferences).to receive(:get) { |key| @settings.fetch(key) }
    @ui = Struct.new(:document, :app, :preferences, :window).new(@document, Struct.new(:executor).new(@executor), preferences, double(request_frame: nil))
    @source = described_class.new(@ui)
  end

  after { @document.close }

  it "caches the count and fetches every cell of a visible row off the rendering thread" do
    calls = []
    rendering_thread = Thread.current
    %i[count displayed_count number_at row time_value].each do |name|
      original = @document.method(name)
      @document.define_singleton_method(name) do |*args|
        calls << name if Thread.current == rendering_thread
        original.call(*args)
      end
    end
    expect(@source.count).to eq(2)
    expect(@source.packet_count).to eq(2)
    expect(@source.row_id(0)).to eq(1)
    expect(@source.value(0, :no)).to eq("1")
    %i[time source destination protocol length info].each { |key| expect(@source.value(0, key)).to be_nil }
    expect(calls).to eq([:number_at])
    @executor.finish
    expect(@source.row_id(0)).to eq(1)
    expect(@source.value(0, :source)).to eq("192.0.2.10")
    expect(@source.value(0, :protocol)).to eq("TCP")
    expect(@source.value(0, :time)).to eq("0.000000")
    expect(@source.value(0, :info)).to be_a(String)
    expect(calls).to eq([:number_at])
  end

  it "rejects a queued row from an earlier reset" do
    @source.value(0, :info)
    @document.sort(:no, :desc).wait
    @source.reset
    @source.value(0, :info)
    @executor.finish
    expect(@source.row_id(0)).to eq(2)
    expect(@source.value(0, :no)).to eq("2")
  end

  it "refreshes stable frame identities after sorting and formats displayed deltas in the background" do
    @settings["packet_list.time_format"] = "delta_displayed"
    @source.reset
    @source.value(0, :time)
    @executor.finish
    @document.sort(:no, :desc).wait
    @source.refresh
    @source.value(0, :time)
    @source.value(1, :time)
    @executor.finish
    expect(@source.row_id(0)).to eq(2)
    expect(@source.row_id(1)).to eq(1)
    expect(@source.index_of(2)).to eq(0)
    expect(@source.value(0, :time)).to eq("0.000000")
    expect(@source.value(1, :time)).to eq("-0.001000")
  end

  it "updates cached packet and display counts when a document notification refreshes its mapping" do
    @document.apply_filter("frame.number == 2").wait
    @source.refresh
    expect(@source.packet_count).to eq(2)
    expect(@source.count).to eq(1)
    expect(@source.row_id(0)).to eq(2)
    @document.apply_filter("").wait
    @source.refresh
    expect(@source.packet_count).to eq(2)
    expect(@source.count).to eq(2)
    expect(@source.row_id(0)).to eq(1)
  end
end
