# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"

RSpec.describe "Gateway field and filter literal contracts" do
  it "returns present false values for unset virtual TCP flags" do
    packet = Vanken::Gateway::Dissector.new.dissect(frame(tcp_bytes(flags: 16)))
    expect(packet.values("tcp.flags.syn")).to eq([false])
    expect(Vanken::Core::DisplayFilter.compile("tcp.flags.syn == false").match?(packet)).to be(true)
    expect(Vanken::Core::DisplayFilter.compile("tcp.flags.syn").match?(packet)).to be(true)
  end

  ["abc\x00".b, "a\nb\t\"\\".b, "\xaa\xff".b].each do |payload|
    it "creates a usable bytes filter for #{payload.inspect}" do
      packet = Vanken::Gateway::Dissector.new.dissect(frame(tcp_bytes(port: 22, payload: payload)))
      node = Vanken::Gateway::DetailBuilder.new.build(packet).flat_map(&:descendants).find { |item| item.field == "data.data" }
      expect(Vanken::Core::DisplayFilter.compile(node.filter, catalog: Vanken::Gateway::FieldCatalog.new).match?(packet)).to be(true)
    end
  end

  it "quotes string annotation values using supported filter escapes" do
    packet = Vanken::Gateway::Dissector.new.dissect(frame)
    annotations = {extra: {"tcp.analysis.label" => "two words\n\"\\"}}
    node = Vanken::Gateway::DetailBuilder.new.build(packet, annotations: annotations).last
    expect { Vanken::Core::DisplayFilter.compile(node.filter) }.not_to raise_error
  end

  it "copies the registry after loading plugins" do
    original = Redhound::Registry.default.copy
    Dir.mktmpdir do |directory|
      path = File.join(directory, "plugin.rb")
      File.write(path, 'Class.new(Redhound::Dissector) { protocol :regression_plugin, name: "Test", short: "TEST" }')
      dissector = Vanken::Gateway::Dissector.new(plugins: [path])
      expect(dissector.registry.protocols).to have_key(:regression_plugin)
    end
  ensure
    Redhound::Registry.instance_variable_set(:@default, original)
  end
end
