# frozen_string_literal: true

# Run: bundle exec ruby --yjit script/analysis-performance.rb [frames=200000]
require "vanken"
require "vanken/app/io_graph"
require_relative "generate_fixtures"

count = Integer(ARGV.fetch(0, "200000"))
raise ArgumentError, "frame count must be positive" unless count.positive?
document = Vanken::App::Document.new(process_analysis: false)
begin
  bytes = VankenFixtures.tcp(seq: 100, flags: 16, payload: "I/O graph benchmark").freeze
  frame = Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: VankenFixtures::TIMESTAMP_NS,
    original_length: bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: 1)
  packet = Vanken::Gateway::Dissector.new.dissect(frame)
  columns, annotations = packet.columns, packet.annotations
  # Seed real disk metadata and compact indices without measuring repeated protocol parsing.
  count.times do |index|
    document.store.append(frame.with(number: index + 1, timestamp_ns: frame.timestamp_ns + (index * 100_000)))
    document.columns.append(columns)
    document.annotations.append(index + 1, annotations)
  end
  document.store.flush
  document.instance_variable_set(:@count, count)
  measurements = Vanken::App::IOGraph::INTERVALS.map do |interval|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Vanken::App::IOGraph.build(document, interval: interval, series: ["", "tcp.port == 80"])
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "I/O graph count mismatch" unless result.map { |series| series.points.sum(&:packets) } == [count, count]
    {interval: interval, seconds: seconds, target_passed: seconds <= 1}
  end
  puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, frames: count, measurements: measurements)
ensure
  document.close
end
