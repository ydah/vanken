# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "../support/packets"
require_relative "../../lib/vanken/gateway/statistics"

RSpec.describe Vanken::Gateway::Statistics do
  it "matches every upstream statistics table and its CLI output" do
    specs = ["phs", *%w[eth ip ipv6 tcp udp].flat_map { |type| ["conv,#{type}", "endpoints,#{type}"] }]
    ethernet = ["02000000000202000000000186dd"].pack("H*")
    udp = [5000, 5353, 12, 0].pack("nnnn") + "test"
    ipv6 = [0x6000_0000, udp.bytesize, 17, 64, IPAddr.new("2001:db8::1").hton, IPAddr.new("2001:db8::2").hton].pack("NnCCa16a16")
    frames = [frame, frame(tcp_bytes(seq: 101, flags: 16, payload: "hello"), number: 2), frame(ethernet + ipv6 + udp, number: 3)]
    statistics = described_class.new(specs: specs)
    frames.each { |value| statistics.update(Vanken::Gateway::Dissector.new.dissect(value)) }
    tables = statistics.tables
    expect(tables.map(&:kind)).to eq([:phs, :conv, :endpoints, :conv, :endpoints, :conv, :endpoints, :conv, :endpoints, :conv, :endpoints])
    tcp = tables.find { |table| table.kind == :conv && table.type == :tcp }.rows.first
    expect(tcp.to_h.slice(:packets_ab, :packets_ba, :bytes_ab, :bytes_ba)).to eq(
      packets_ab: 2, packets_ba: 0, bytes_ab: frames.take(2).sum(&:original_length), bytes_ba: 0)
    expect(tables.find { |table| table.kind == :endpoints && table.type == :tcp }.rows.sum { |row| row.packets_tx }).to eq(2)
    expect(tables.find { |table| table.kind == :conv && table.type == :ipv6 }.rows.first.addr_a).to eq("2001:db8::1")
    expect(tables.find { |table| table.kind == :conv && table.type == :udp }.rows.first.packets_ab).to eq(1)
    Dir.mktmpdir do |directory|
      path = write_capture(File.join(directory, "statistics.pcapng"), frames)
      out, err = StringIO.new, StringIO.new
      expect(Redhound::CLI::Command.new.run(["-r", path, *specs.flat_map { |specification| ["--stats", specification] }], out: out, err: err)).to eq(0)
      tables.each do |table|
        expect(err.string).to include("#{table.kind}#{table.type ? ",#{table.type}" : ''}")
        table.rows.each do |row|
          text = row.to_h.map { |name, value| "#{name}=#{value.is_a?(Array) ? value.join(':') : value}" }.join(" ")
          expect(err.string).to include(text)
        end
      end
    end
  ensure
    statistics&.close
  end

  it "owns immutable snapshots while subsequent packets update the same session" do
    statistics = described_class.new(specs: ["conv,tcp"])
    statistics.update(Vanken::Gateway::Dissector.new.dissect(frame))
    before = statistics.tables.first
    statistics.update(Vanken::Gateway::Dissector.new.dissect(frame(number: 2)))
    expect(before.rows.first.packets_ab).to eq(1)
    expect(statistics.tables.first.rows.first.packets_ab).to eq(2)
    expect(before).to be_frozen
    expect(before.rows).to be_frozen
    expect(before.rows.first).to be_frozen
  ensure
    statistics&.close
  end
end
