# frozen_string_literal: true

require "spec_helper"
require "csv"
require_relative "../support/packets"
require_relative "../../lib/vanken/gateway/exporter"

RSpec.describe Vanken::Gateway::Exporter do
  let(:doc) { Vanken::App::Document.new(process_analysis: false) }
  let(:exporter) { described_class.new(doc) }
  before do
    5.times do |index|
      value = frame(number: index + 1)
      doc.store.append(value)
      doc.store.flush
      doc.publish(value.number, Vanken::Gateway::Dissector.new.dissect(value))
    end
    doc.marked.merge([2, 4])
    doc.ignored << 3
  end
  after { doc.close }

  it "selects all supported packet scopes with strict closed/open range validation" do
    expect(exporter.numbers(scope: :range, range: "1-2,4-", exclude_ignored: true)).to eq([1, 2, 4, 5])
    expect(exporter.numbers(scope: :marked)).to eq([2, 4])
    expect(exporter.numbers(scope: :between_marks)).to eq([2, 3, 4])
    expect(exporter.numbers(scope: :selected, selected: 5)).to eq([5])
    doc.apply_filter("frame.number > 3").wait
    expect(exporter.numbers(scope: :displayed)).to eq([4, 5])
    ["0", "6", "3-2", "1--3", "2,", "1-6"].each { |range| expect { exporter.numbers(scope: :range, range: range) }.to raise_error(ArgumentError) }
  end

  it "exports upstream-schema JSON, NDJSON, detail text, current CSV columns, and packet captures" do
    Dir.mktmpdir do |directory|
      json = File.join(directory, "packets.json")
      exporter.write(json, format: :json, numbers: [2, 4])
      values = JSON.parse(File.read(json))
      schema = JSON.parse(File.read(File.join(Gem.loaded_specs.fetch("redhound").full_gem_path, "docs/json-schema.json")))
      values.each do |value|
        expect(value.keys.sort).to eq(schema.fetch("required").sort)
        expect(value.fetch("frame").keys.sort).to eq(schema.dig("properties", "frame", "required").sort)
        expect(value.fetch("frame").fetch("time_epoch_ns")).to be_a(Integer)
        expect(value.fetch("layers").map { |layer| layer.fetch("fields") }.any? { |fields| fields.key?("tcp.stream") }).to be(true)
      end
      expect(values.map { |value| value.dig("frame", "number") }).to eq([2, 4])
      ndjson = File.join(directory, "packets.ndjson")
      exporter.write(ndjson, format: :ndjson, numbers: [2, 4])
      expect(File.readlines(ndjson).map { |line| JSON.parse(line) }).to eq(values)
      text = File.join(directory, "packets.txt")
      exporter.write(text, format: :text, numbers: [2])
      expect(File.read(text)).to include("Frame 2:", "Transmission Control Protocol")
      csv = File.join(directory, "packets.csv")
      exporter.write(csv, format: :csv, numbers: [2], columns: [{key: :number, label: "No."}, {key: :source, label: "Source"}])
      expect(CSV.read(csv)).to eq([["No.", "Source"], ["2", "192.0.2.10"]])
      pcap = File.join(directory, "packets.pcap")
      exporter.write(pcap, format: :pcap, numbers: [2, 4])
      reader = Vanken::Gateway::FileReader.new(pcap)
      expect([reader.next_frame.bytes, reader.next_frame.bytes]).to eq([frame.bytes, frame.bytes])
      expect(reader.next_frame).to be_nil
      reader.close
      [json, ndjson, text, csv, pcap].each { |path| expect(File.stat(path).mode & 0o777).to eq(0o600) }
    end
  end

  it "does not replace an existing output when serialization fails" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "original")
      File.write(path, "keep")
      expect { exporter.write(path, format: :json, numbers: [99]) }.to raise_error(IndexError)
      expect(File.read(path)).to eq("keep")
      expect(Dir.children(directory)).to eq(["original"])
    end
  end
end
