# frozen_string_literal: true

require "spec_helper"

RSpec.describe Vanken::Core::ColumnStore do
  def columns(source_port: 123, destination_port: 456, layers: ["eth", "ip", "udp"], transport_values: nil)
    {source: "a", destination: "b", protocol: "UDP", src_port: source_port, dst_port: destination_port,
     ip_proto: 17, layers: layers, transport_values: transport_values}
  end

  it "looks up packed transport fields without allocating an entire packet row" do
    store = described_class.new
    store.append(columns)
    expect(store.port_values(1, "udp.port")).to eq([123, 456])
    expect(store.port_values(1, "udp.srcport")).to eq([123])
    expect(store.port_values(1, "udp.dstport")).to eq([456])
    before = GC.stat(:total_allocated_objects)
    1_000.times { store.port_values(1, "udp.port") }
    allocations = GC.stat(:total_allocated_objects) - before
    expect(allocations).to be < 4_000
  end

  it "preserves absent ports and repeated embedded transport values" do
    store = described_class.new
    store.append(columns(source_port: -1, destination_port: -1))
    store.append(columns(transport_values: {"udp.srcport" => [123, 789], "udp.dstport" => [456, 890]}))
    expect(store.port_values(1, "udp.port")).to eq([])
    expect(store.port_values(1, "tcp.port")).to eq([])
    expect(store.port_values(2, "udp.port")).to eq([123, 789, 456, 890])
    expect(store.port_values(2, "udp.srcport")).to eq([123, 789])
  end
end

RSpec.describe Vanken::Core::AnnotationStore do
  it "retains expert counts and maximum severity across packed publication batches" do
    Dir.mktmpdir do |directory|
      worker = described_class.new(directory, persist: false)
      annotation = {tcp_stream: -1, seq_rel: -1, ack_rel: -1, analysis_flags: [], expert_max: 2,
        expert_items: [{severity: :warning, code: "test"}], extra: {}}
      worker.append(1, annotation)
      worker.append(2, annotation.merge(expert_max: 3, expert_items: [{severity: :error, code: "error"}]))
      parent = described_class.new(directory)
      parent.import(worker.drain)
      expect([parent.expert_count, parent.expert_max]).to eq([2, 3])
      expect([worker.expert_count, worker.expert_max]).to eq([0, 0])
      parent.append(3, annotation)
      expect([parent.expert_count, parent.expert_max]).to eq([3, 3])
      parent.close
    end
  end
end
