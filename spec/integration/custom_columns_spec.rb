# frozen_string_literal: true

require "spec_helper"
require "vanken/config/columns"
require_relative "../support/packets"

RSpec.describe "Typed custom packet columns" do
  before do
    @document = Vanken::App::Document.new(process_analysis: false)
    packets = [10, 2, 100].each_with_index.map do |ttl, index|
      bytes = tcp_bytes(port: 80 + index)
      bytes.setbyte(22, ttl)
      frame(bytes, number: index + 1)
    end
    @document.ingest(packets).wait
    @settings = Vanken::Config::Columns.new
    @settings.add("ip.ttl", label: "TTL")
    @settings.add("tcp.flags.syn")
    @document.custom_columns = @settings.custom
  end
  after { @document.close }

  it "extracts raw field values and sorts numeric columns numerically with stable ties" do
    expect(@document.row(1)[:"field:ip.ttl"]).to eq("10")
    expect(@document.row(1)[:"field:tcp.flags.syn"]).to eq("true")
    @document.sort(:"field:ip.ttl").wait
    expect(@document.display_numbers).to eq([2, 1, 3])
    @document.sort(:"field:ip.ttl", :desc).wait
    expect(@document.display_numbers).to eq([3, 1, 2])
    @document.sort(:"field:tcp.flags.syn").wait
    expect(@document.display_numbers).to eq([1, 2, 3])
    expect(@document.error).to be_nil
  end

  it "searches visible custom values and handles missing fields without failing sort" do
    @settings.add("tcp.dstport")
    @settings.add("udp.dstport")
    @document.custom_columns = @settings.custom
    result = Queue.new
    @document.search("81", mode: :string, target: :list, from: 1) { |hit, error| result << [hit, error] }
    expect(result.pop).to eq([2, nil])
    expect(@document.row(1)[:"field:udp.dstport"]).to eq("")
    @document.sort(:"field:udp.dstport").wait
    expect(@document.display_numbers).to eq([1, 2, 3])
    expect(@document.error).to be_nil
  end
end
