# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/packet_source"
require_relative "../support/packets"

RSpec.describe Vanken::UI::PacketSource do
  class RowExecutor
    def initialize = (@background, @posted = [], [])
    def background(&block) = @background << block
    def post(&block) = @posted << block
    def background_count = @background.size
    def posted_count = @posted.size
    def work
      jobs, @background = @background, []
      Thread.new { jobs.each(&:call) }.join
    end
    def drain
      posts, @posted = @posted, []
      posts.each(&:call)
    end
    def finish = (drain; work; drain)
  end

  RowUI = Struct.new(:document, :app, :preferences, :window, :table, :following) do
    def autoscroll? = following
  end

  def prime_viewport
    @source.value(0, :info)
    @source.value(1, :info)
    @executor.finish
  end

  def append_packet(number)
    item = frame(number: number, timestamp_ns: 1_700_000_000_123_456_789 + ((number - 1) * 1_000_000))
    @document.store.append(item)
    @document.store.flush
    @document.publish(number, Vanken::Gateway::Dissector.new.dissect(item))
  end

  before do
    @document = Vanken::App::Document.new.ingest([frame, frame(number: 2, timestamp_ns: 1_700_000_000_124_456_789)]).wait
    @executor = RowExecutor.new
    @settings = {"packet_list.time_format" => "relative", "packet_list.time_precision" => "micro", "packet_list.row_cache_rows" => 20_000}
    preferences = double(get: nil)
    allow(preferences).to receive(:get) { |key| @settings.fetch(key) }
    table = Struct.new(:body).new(Struct.new(:visible_range).new(0...2))
    @ui = RowUI.new(@document, Struct.new(:executor).new(@executor), preferences, double(request_frame: nil), table, false)
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

  it "fetches a viewport in one background batch and publishes all its cells once" do
    expect(@ui.window).to receive(:request_frame).once
    %i[time source protocol info].each do |key|
      expect(@source.value(0, key)).to be_nil
      expect(@source.value(1, key)).to be_nil
    end
    expect(@executor.background_count).to eq(0)
    expect(@executor.posted_count).to eq(1)
    @executor.drain
    expect(@executor.background_count).to eq(1)
    expect(@executor.posted_count).to eq(0)
    @executor.work
    expect(@executor.posted_count).to eq(1)
    @executor.drain
    expect(@source.value(0, :protocol)).to eq("TCP")
    expect(@source.value(1, :time)).to eq("0.001000")
    expect(@executor.background_count).to eq(0)
    expect(@executor.posted_count).to eq(0)
  end

  it "rejects an earlier batch publication without clearing requests made after reset" do
    expect(@ui.window).to receive(:request_frame).once
    @source.value(0, :time)
    @executor.drain
    @executor.work
    @document.sort(:no, :desc).wait
    @source.reset
    @source.value(0, :time)
    @source.value(1, :time)
    @executor.drain
    expect(@source.value(1, :time)).to be_nil
    @executor.finish
    expect(@source.value(0, :time)).to eq("0.001000")
    expect(@source.value(1, :time)).to eq("0.000000")
  end

  it "publishes successful rows and retries a failed row in the next batch" do
    expect(@ui.window).to receive(:request_frame).twice
    allow(@document).to receive(:row).and_call_original
    allow(@document).to receive(:row).with(2).and_raise(IndexError, "transient row failure")
    @source.value(0, :info)
    @source.value(1, :info)
    @executor.finish
    expect(@source.value(0, :info)).to be_a(String)
    expect(@source.value(1, :info)).to be_nil
    allow(@document).to receive(:row).with(2).and_call_original
    @executor.finish
    expect(@source.value(1, :info)).to be_a(String)
  end

  it "keeps the old viewport until the new count and complete tail rows can publish together" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = []
    expect(@ui.window).not_to receive(:request_frame)
    @source.refresh { published << [@source.count, @source.value(2, :protocol), @source.value(2, :time)] }
    expect(@source.count).to eq(2)
    expect(@source.value(1, :protocol)).to eq("TCP")
    expect(published).to be_empty
    expect(@executor.background_count).to eq(1)
    @executor.work
    expect(@source.count).to eq(2)
    @executor.drain
    expect(published).to eq([[3, "TCP", "0.002000"]])
    expect(@executor.background_count).to eq(0)
    expect(@executor.posted_count).to eq(0)
  end

  it "coalesces growing notifications into one pending tail refresh and one latest follow-up" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = []
    @source.refresh { published << [:first, @source.count] }
    (4..8).each do |number|
      append_packet(number)
      @source.refresh { published << [number, @source.count] }
    end
    expect(@source.count).to eq(2)
    expect(@executor.background_count).to eq(1)
    @executor.work
    @executor.drain
    expect(published).to eq([[:first, 3]])
    expect(@source.count).to eq(3)
    expect(@executor.background_count).to eq(1)
    @executor.work
    @executor.drain
    expect(published).to eq([[:first, 3], [8, 8]])
    expect(@source.value(7, :protocol)).to eq("TCP")
    expect(@executor.background_count).to eq(0)
    expect(@executor.posted_count).to eq(0)
  end

  it "coalesces duplicate counts into the latest callback without erasing primed displayed deltas" do
    @settings["packet_list.time_format"] = "delta_displayed"
    @source.reset
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = []
    @source.refresh { published << [:first, @source.value(2, :time)] }
    @source.refresh { published << [:latest, @source.value(2, :time)] }
    expect(@executor.background_count).to eq(1)
    @executor.work
    @executor.drain
    expect(published).to eq([[:latest, "0.001000"]])
    expect(@source.value(2, :time)).to eq("0.001000")
    expect(@executor.background_count).to eq(0)
    expect(@executor.posted_count).to eq(0)
  end

  it "discards a queued tail publication after reset" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = false
    @source.refresh { published = true }
    expect(@executor.background_count).to eq(1)
    @executor.work
    @source.reset
    @executor.drain
    expect(published).to be(false)
    expect(@source.count).to eq(3)
    expect(@source.value(2, :info)).to be_nil
  end

  it "discards tail rows and their callback after changing documents" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = false
    @source.refresh { published = true }
    expect(@executor.background_count).to eq(1)
    @ui.document = nil
    @executor.finish
    expect(published).to be(false)
    @source.refresh
    expect(@source.count).to eq(0)
  end

  it "publishes immediately after tail following is disabled and rejects the older tail result" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    published = []
    @source.refresh { published << [:old, @source.count] }
    @ui.following = false
    append_packet(4)
    @source.refresh { published << [:current, @source.count] }
    expect(published).to eq([[:current, 4]])
    @executor.finish
    expect(published).to eq([[:current, 4]])
    expect(@source.count).to eq(4)
  end

  it "publishes the tail count with successful rows and leaves a failed row retryable" do
    prime_viewport
    @ui.following = true
    append_packet(3)
    allow(@document).to receive(:row).and_call_original
    allow(@document).to receive(:row).with(3).and_raise(IndexError, "transient row failure")
    published = []
    @source.refresh { published << [@source.count, @source.value(2, :protocol)] }
    @executor.work
    @executor.drain
    expect(published).to eq([[3, nil]])
    expect(@source.value(1, :protocol)).to eq("TCP")
    allow(@document).to receive(:row).with(3).and_call_original
    @executor.finish
    expect(@source.value(2, :protocol)).to eq("TCP")
  end

  it "formats tail displayed deltas using the ordering captured before background work" do
    @settings["packet_list.time_format"] = "delta_displayed"
    @source.reset
    prime_viewport
    @ui.following = true
    (3..8).each { |number| append_packet(number) }
    published = []
    @source.refresh { published << [@source.row_id(7), @source.value(7, :time)] }
    @document.sort(:no, :desc).wait
    @executor.work
    @executor.drain
    expect(published).to eq([[8, "0.001000"]])
  end

  it "honors the selected precision for absolute timestamps" do
    @settings["packet_list.time_format"] = "absolute"
    @settings["packet_list.time_precision"] = "milli"
    @source.reset
    @source.value(0, :time)
    @executor.finish
    expect(@source.value(0, :time)).to match(/\A\d{2}:\d{2}:\d{2}\.123\z/)
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

  it "adds custom cells to the same background batch without parsing on the UI thread" do
    @document.custom_columns = [{"key" => "field:ip.ttl", "field" => "ip.ttl", "visible" => true}]
    rendering_thread = Thread.current
    original = @document.method(:custom_row)
    @document.define_singleton_method(:custom_row) do |number|
      raise "custom column parsed on rendering thread" if Thread.current == rendering_thread
      original.call(number)
    end
    expect(@source.value(0, :"field:ip.ttl")).to be_nil
    expect(@source.value(1, :"field:ip.ttl")).to be_nil
    @executor.drain
    expect(@executor.background_count).to eq(1)
    @executor.work
    @executor.drain
    expect(@source.value(0, :"field:ip.ttl")).to eq("64")
    expect(@source.value(1, :"field:ip.ttl")).to eq("64")
  end

  it "uses selection text before packet colors while retaining ignored strikethrough" do
    theme = Struct.new(:colors).new(Struct.new(:text).new(:selected_text))
    allow(@ui.app).to receive(:global).with(:theme).and_return(theme)
    @ui.table = Struct.new(:selection).new(Set[1])
    @document.marked.add(1)
    expect(@source.row_style(0)).to eq(foreground: :selected_text, strikethrough: false)
    @document.ignored.add(1)
    expect(@source.row_style(0)).to eq(foreground: :selected_text, strikethrough: true)
  end

  it "invalidates only resolved rows and rejects publications queued before the update" do
    prime_viewport
    @source.invalidate_rows([1])
    expect(@source.value(0, :source)).to be_nil
    expect(@source.value(1, :source)).to eq("192.0.2.10")
    @executor.drain
    @executor.work
    @source.invalidate_rows([1])
    @executor.drain
    expect(@source.value(0, :source)).to be_nil
    expect(@source.value(1, :source)).to eq("192.0.2.10")
    @executor.finish
    expect(@source.value(0, :source)).to eq("192.0.2.10")
  end
end
