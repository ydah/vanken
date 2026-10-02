# frozen_string_literal: true

require "spec_helper"
require "vanken/app/navigation"
require_relative "../support/packets"

RSpec.describe "Packet search and navigation" do
  before do
    @document = Vanken::App::Document.new(process_analysis: false)
    @document.extend(Vanken::App::Navigation)
    @document.ingest([frame, frame(tcp_bytes(seq: 101, flags: 24, payload: "GET /needle HTTP/1.1\r\nHost: example.test\r\n\r\n"), number: 2, timestamp_ns: 1_700_000_001_123_456_789),
                      frame(tcp_bytes(port: 443, payload: "\xff\x80".b), number: 3, timestamp_ns: 1_700_000_002_123_456_789)]).wait
  end
  after { @document.cancel_search; @document.close }

  def find(query, **options)
    result = Queue.new
    @document.search(query, **options) { |hit, error| result << [hit, error] }
    hit, error = result.pop
    raise error if error
    hit
  end

  it "searches four modes and all targets without changing the display filter" do
    expect(find("http", mode: :filter, from: 1)).to eq(2)
    expect(find("47 45 54 20 2f 6e 65 65 64 6c 65", mode: :hex, target: :bytes, from: 1)).to eq(2)
    expect(find("needle", mode: :string, target: :list, from: 1)).to eq(2)
    expect(find("example\\.test", mode: :regex, target: :details, from: 1)).to eq(2)
    expect(find("needle", mode: :string, target: :bytes, from: 3, direction: -1)).to eq(2)
    expect(find("ff:80", mode: :hex, target: :bytes, from: 2)).to eq(3)
    expect(find("\\xff\\x80", mode: :regex, target: :bytes, from: 2)).to eq(3)
    expect(@document.filter).to be_nil
    expect(@document.display_numbers).to eq([1, 2, 3])
  end

  it "honors the displayed order and wraps in either direction" do
    @document.apply_filter("frame.number != 1").wait
    @document.sort(:no, :desc).wait
    expect(find("tcp", mode: :filter, from: 2)).to eq(3)
    expect(find("tcp", mode: :filter, from: 3, direction: -1)).to eq(2)
    expect(find("never-present", mode: :string, target: :bytes, from: 3)).to be_nil
  end

  it "marks displayed packets, toggles ignore and time references, and follows stream reverse indices" do
    @document.apply_filter("frame.number <= 2").wait
    @document.mark_all_displayed
    expect(@document.marked.to_a).to eq([1, 2])
    @document.toggle_mark(1)
    expect(@document.marked.to_a).to eq([2])
    @document.toggle_ignore(2)
    @document.toggle_time_reference(2)
    expect(@document.ignored.to_a).to eq([2])
    expect(@document.time_value(2)).to eq(0.0)
    expect(@document.conversation_neighbor(1, 1)).to eq(2)
    expect(@document.conversation_neighbor(2, -1)).to eq(1)
    expect(@document.conversation_neighbor(2, 1)).to be_nil
    @document.unmark_all
    expect(@document.marked).to be_empty
  end

  it "rejects invalid queries and cancels a scan before delivering a stale match" do
    expect { find("[", mode: :regex) }.to raise_error(Vanken::Error)
    expect { find("a b c", mode: :hex) }.to raise_error(Vanken::Error)
    entered, release, results = Queue.new, Queue.new, Queue.new
    original = @document.method(:row)
    @document.define_singleton_method(:row) do |number|
      entered << true
      release.pop
      original.call(number)
    end
    @document.search("needle", mode: :string, target: :list) { |*value| results << value }
    entered.pop
    @document.cancel_search
    release << true
    @document.wait(2)
    expect(results).to be_empty
  end

  it "refreshes active mark, ignore, and relative time filters after state changes" do
    @document.apply_filter("frame.marked == true").wait
    expect(@document.display_numbers).to be_empty
    @document.toggle_mark(2).wait
    expect(@document.display_numbers).to eq([2])
    @document.toggle_mark(2).wait
    expect(@document.display_numbers).to be_empty
    @document.apply_filter("frame.ignored == true").wait
    @document.toggle_ignore(3).wait
    expect(@document.display_numbers).to eq([3])
    @document.apply_filter("frame.time_relative >= 1").wait
    expect(@document.display_numbers).to eq([2, 3])
    @document.toggle_time_reference(2).wait
    expect(@document.display_numbers).to eq([3])
  end
end
