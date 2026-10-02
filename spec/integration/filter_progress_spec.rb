# frozen_string_literal: true

require "spec_helper"
require "zaniah"
require "vanken/capture/filter_worker"
require "timeout"
require_relative "../support/packets"

RSpec.describe "Progressive filtering while packets arrive" do
  def wait_until
    Timeout.timeout(5) { sleep(0.001) until yield }
  end

  def publish(number)
    incoming = frame(number: number)
    @document.store.append(incoming)
    @document.store.flush
    @document.publish(number, Vanken::Gateway::Dissector.new.dissect(incoming))
  end

  after { @document&.close }

  it "keeps each historical chunk before matching live packets throughout progress" do
    submitted = Queue.new
    scanner = ->(payload) do
      task = Zaniah::Task.new
      submitted << [payload, task]
      task
    end
    frames = Enumerator.new { |stream| 20_002.times { |index| stream << frame(number: index + 1) } }
    @document = Vanken::App::Document.new(scanner: scanner).ingest(frames).wait(10)
    expression = "ip.src == 192.0.2.10 and frame.number in {1 9999 10001 19999 20001 20003 20005}"
    @document.apply_filter(expression)
    pending = 3.times.map { Timeout.timeout(5) { submitted.pop } }
    expect(pending.map { |payload, _| payload.values_at("from", "to") }).to eq([[1, 10_001], [10_001, 20_001], [20_001, 20_003]])

    publish(20_003)
    publish(20_004)
    pending[0][1].resolve({"matches" => [1, 9999]})
    wait_until { @document.display_numbers == [1, 9999, 20_003] }
    publish(20_005)
    pending[1][1].resolve({"matches" => [10_001, 19_999]})
    wait_until { @document.display_numbers == [1, 9999, 10_001, 19_999, 20_003, 20_005] }
    pending[2][1].resolve({"matches" => [20_001]})
    @document.wait(5)
    expect(@document.display_numbers).to eq([1, 9999, 10_001, 19_999, 20_001, 20_003, 20_005])
    expect(@document.error).to be_nil
    expect(@document.progress).to be_nil
  end

  it "clears immediately without reading or evaluating historical packets" do
    @document = Vanken::App::Document.new.ingest([frame, frame(number: 2)]).wait(2)
    @document.apply_filter("frame.number == 1").wait(2)
    allow(@document).to receive(:view).and_raise("clear attempted to read packet data")
    @document.apply_filter("").wait(2)
    expect(@document.display_numbers).to eq([1, 2])
    expect(@document.error).to be_nil
    expect(@document.filter).to be_nil
    expect(@document.progress).to be_nil
  end

  it "captures displayed predecessors only for filters that use them, including explicit worker expressions" do
    submitted = Queue.new
    scanner = ->(payload) do
      task = Zaniah::Task.new
      submitted << [payload, task]
      task
    end
    frames = 3.times.map { |index| frame(number: index + 1, timestamp_ns: (index + 1) * 1_000_000_000) }
    @document = Vanken::App::Document.new(scanner: scanner).ingest(frames).wait(2)
    @document.apply_filter("frame.number != 2").wait(2)
    @document.apply_filter("ip.ttl == 64")
    _, task = Timeout.timeout(5) { submitted.pop }
    expect(@document.instance_variable_get(:@filter_context)[:predecessors]).to be_nil
    task.resolve({"matches" => [1, 2, 3]})
    @document.wait(2)

    @document.apply_filter("frame.number != 2").wait(2)
    expression = "ip.ttl == 64 and frame.time_delta_displayed == 2"
    payload = @document.filter_payload(1, 4, expression: expression)
    expect(payload["displayed_predecessors"]).to eq("1" => 0, "2" => 0, "3" => 1)
    expect(Vanken::Capture::FilterWorker.call(payload)).to eq("matches" => [3])
    @document.apply_filter(expression)
    payload, task = Timeout.timeout(5) { submitted.pop }
    expect(@document.instance_variable_get(:@filter_context)[:predecessors]).to eq(1 => 0, 3 => 1)
    task.resolve(Vanken::Capture::FilterWorker.call(payload))
    @document.wait(2)
    expect(@document.display_numbers).to eq([3])
    expect(@document.error).to be_nil
  end
end
