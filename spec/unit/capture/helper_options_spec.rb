# frozen_string_literal: true

require "spec_helper"
require "vanken/capture/helper_options"

RSpec.describe Vanken::Capture::HelperOptions do
  it "accepts the capture options without interpreting shell characters" do
    options = described_class.parse(%w[-i eth0 --filter] + ["tcp; echo boom"] + %w[--snaplen 4096 --direction in --backend socket --drop-to 1000:1000])
    expect(options.capture).to include(interface: "eth0", filter: "tcp; echo boom", snaplen: 4096, direction: :in, backend: :socket)
    expect(options.drop_to).to eq([1000, 1000])
    expect(options.flush_interval).to eq(0.05)
    expect(options.stats_interval).to eq(1.0)
  end

  it "rejects unknown, abbreviated, trailing, and conflicting arguments" do
    [%w[-i eth0 --wat], %w[-i eth0 --snap 100], %w[-i eth0 extra], %w[--check --list-interfaces], []].each do |argv|
      expect { described_class.parse(argv) }.to raise_error(ArgumentError)
    end
  end

  it "bounds all numeric options and refuses a root drop target" do
    {"--snaplen" => %w[0 -1 999999999999], "--buffer-size" => %w[0 -1 999999999999],
      "--flush-interval" => %w[0 NaN Infinity 100], "--stats-interval" => %w[0 NaN Infinity 100],
      "--drop-to" => %w[0:0 -1:1000 1000:0 1000:x 1:2:3]}.each do |option, values|
      values.each { |value| expect { described_class.parse(["-i", "eth0", option, value]) }.to raise_error(ArgumentError) }
    end
  end

  it "supports non-capture commands without requiring an interface" do
    expect(described_class.parse(%w[--list-interfaces]).command).to eq(:list_interfaces)
    expect(described_class.parse(%w[--check]).command).to eq(:check)
    expect(described_class.parse(%w[--version]).command).to eq(:version)
  end

  it "accepts bounded automatic stop conditions without opening output paths" do
    options = described_class.parse(%w[-i eth0 --stop-count 25 --stop-duration 1.5 --stop-bytes 1024])
    expect(options.stop_count).to eq(25)
    expect(options.stop_duration).to eq(1.5)
    expect(options.stop_bytes).to eq(1024)
    %w[--stop-count --stop-duration --stop-bytes].each do |option|
      %w[0 -1 NaN Infinity].each do |value|
        expect { described_class.parse(["-i", "eth0", option, value]) }.to raise_error(ArgumentError)
      end
    end
    expect { described_class.parse(%w[-i eth0 --ring-path /tmp/capture]) }.to raise_error(ArgumentError)
  end
end
