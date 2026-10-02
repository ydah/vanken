# frozen_string_literal: true

require "spec_helper"
require "vanken/gateway/interfaces"

RSpec.describe Vanken::Gateway::Interfaces do
  it "reads Linux byte counters and ignores unrelated columns" do
    input = "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n lo: 123 4 0 0 0 0 0 0 456 4 0 0 0 0 0 0\n eth0: 1000 3 0 0 0 0 0 0 2000 3 0 0 0 0 0 0\n"
    expect(described_class.parse_linux_counters(input)).to eq("lo" => 579, "eth0" => 3000)
  end

  it "reads each macOS link once instead of summing duplicate IPv4/IPv6 rows" do
    input = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\n en0 1500 <Link#4> aa:bb 10 0 1000 20 0 2000 0\n en0 1500 192.0.2 192.0.2.1 10 - 1000 20 - 2000 -\n lo0 16384 <Link#1> 3 0 600 3 0 600 0\n"
    expect(described_class.parse_darwin_counters(input)).to eq("en0" => 3000, "lo0" => 1200)
  end

  it "keeps sixty one-second samples and handles interface resets without negative traffic" do
    allow(described_class).to receive(:traffic_counters).and_return({"en0" => 1000}, {"en0" => 2500}, {"en0" => 5})
    first = described_class.sample_traffic(now: 0)
    second = described_class.sample_traffic(previous: first[:previous], history: {"en0" => Array.new(60, 10)}, now: 1)
    expect(second[:rates]).to eq("en0" => 1500)
    expect(second[:history]["en0"].size).to eq(60)
    expect(second[:history]["en0"].last).to eq(1500)
    reset = described_class.sample_traffic(previous: second[:previous], history: second[:history], now: 2)
    expect(reset[:rates]).to eq("en0" => 0)
  end
end
