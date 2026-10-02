# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"
require_relative "../../lib/vanken/app/stats_job"
require_relative "../../lib/vanken/app/io_graph"
require_relative "../../lib/vanken/app/expert_info"

RSpec.describe "Analysis jobs" do
  let(:doc) { Vanken::App::Document.new(process_analysis: false) }
  after { @job&.cancel; doc.close }
  def append(value)
    doc.store.append(value)
    doc.store.flush
    doc.publish(value.number, Vanken::Gateway::Dissector.new.dissect(value))
  end

  it "adds live packets once and restarts a displayed-only session when filtering changes" do
    append(frame)
    @job = Vanken::App::StatsJob.new(doc, specs: ["conv,tcp"], displayed_only: true)
    expect(@job.refresh.first.rows.first.packets_ab).to eq(1)
    append(frame(number: 2))
    expect(@job.refresh.first.rows.first.packets_ab).to eq(2)
    expect(@job.refresh.first.rows.first.packets_ab).to eq(2)
    doc.apply_filter("frame.number == 2").wait
    expect(@job.refresh.first.rows.first.packets_ab).to eq(1)
    @job.cancel
    expect(@job.refresh).to eq([])
  end

  it "aggregates expert messages by severity, code, and protocol and retains frame navigation" do
    doc.annotations.append(1, tcp_stream: -1, seq_rel: -1, ack_rel: -1, analysis_flags: [], expert_max: 2,
      expert_items: [{severity: :warning, code: "bad_checksum", protocol: "tcp", message: "one"}], extra: {})
    doc.annotations.append(2, tcp_stream: -1, seq_rel: -1, ack_rel: -1, analysis_flags: [], expert_max: 3,
      expert_items: [{severity: :warning, code: "bad_checksum", protocol: "tcp", message: "two"},
                    {severity: :error, code: "truncated", protocol: "ip", message: "short"}], extra: {})
    rows = Vanken::App::ExpertInfo.rows(doc)
    expect(rows.map { |row| [row.severity, row.code, row.count, row.numbers] }).to eq([
      [:error, "truncated", 1, [2]], [:warning, "bad_checksum", 2, [1, 2]]])
  end

  it "bins packet lengths and timestamps with independently filtered series and empty gaps" do
    [0, 1_000_000_000, 3_000_000_000].each_with_index { |offset, index| append(frame(number: index + 1, timestamp_ns: 100_000_000_000 + offset)) }
    result = Vanken::App::IOGraph.build(doc, interval: 1, series: ["", "frame.number == 2"])
    expect(result.first.points.map(&:packets)).to eq([1, 1, 0, 1])
    expect(result.last.points.map(&:packets)).to eq([0, 1, 0, 0])
    expect(result.first.points.sum(&:bytes)).to eq(3 * frame.original_length)
    expect(result.first.points.first.start_ns).to eq(100_000_000_000)
    expect { Vanken::App::IOGraph.build(doc, interval: 0.5) }.to raise_error(ArgumentError)
  end
end
