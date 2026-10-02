# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"

RSpec.describe Vanken::Core::FrameView do
  after { @document&.close }

  it "evaluates packed columns without allocating unrelated frame metadata" do
    @document = Vanken::App::Document.new
    @document.store.append(frame)
    @document.store.flush
    @document.publish(1, Vanken::Gateway::Dissector.new.dissect(frame))
    program = Vanken::Core::DisplayFilter.compile("tcp and tcp.port == 80", catalog: @document.catalog)
    expect(program.match?(@document.view(1))).to be(true)
    before = GC.stat(:total_allocated_objects)
    1_000.times { program.match?(@document.view(1)) }
    allocations = GC.stat(:total_allocated_objects) - before
    expect(allocations).to be < 7_000
    view = @document.view(1)
    expect(view.values("frame.number")).to eq([1])
    expect(view.values("frame.len")).to eq([frame.original_length])
    expect(view.values("frame.time_epoch")).to eq([frame.timestamp_ns / 1e9])
  end
end
