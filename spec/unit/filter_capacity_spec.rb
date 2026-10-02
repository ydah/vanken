# frozen_string_literal: true

require "spec_helper"
require "objspace"
require_relative "../support/packets"

RSpec.describe "historical filter storage" do
  after { @document&.close }

  it "reserves the known history once while publishing ordinary frame numbers without nil rows" do
    @document = Vanken::App::Document.new
    incoming = frame
    packet = Vanken::Gateway::Dissector.new.dissect(incoming)
    20_001.times do |index|
      @document.store.append(incoming)
      @document.publish(index + 1, packet)
    end
    @document.store.flush
    @document.apply_filter("frame.number > 0").wait(5)
    expect(@document.error).to be_nil
    expect(@document.displayed_count).to eq(20_001)
    expect(@document.number_at(0)).to eq(1)
    expect(@document.number_at(20_000)).to eq(20_001)
    numbers = @document.instance_variable_get(:@display)
    expect(numbers).not_to include(nil)
    expect(ObjectSpace.memsize_of(numbers)).to be < (numbers.size * 9)
  end
end
