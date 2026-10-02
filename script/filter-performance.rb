# frozen_string_literal: true

require_relative "benchmark"

count = Integer(ARGV.fetch(0, "20000"))
raise ArgumentError, "frames must be between 1 and 1000000" unless count.between?(1, 1_000_000)
expression = "ip.addr == 192.0.2.1 && udp.port == 54321"
program = Vanken::Core::DisplayFilter.compile(expression)
capture = Vanken::Gateway::DisplayCaptureFilter.new(expression)
dissector = Vanken::Gateway::Dissector.new
frame = Vanken::Core::Frame.new(bytes: VankenBenchmark.datagram, timestamp_ns: 0,
  original_length: VankenBenchmark.datagram.bytesize, linktype: 1, interface: nil, direction: nil, number: 1)
results = {}
{vdf: -> { program.match?(dissector.dissect(frame)) }, cbpf: -> { capture.match(frame) }}.each do |name, match|
  times = 3.times.map do
    started = VankenBenchmark.now
    matched = count.times.count { match.call }
    raise "filter lost matching frames" unless matched == count
    VankenBenchmark.now - started
  end
  results[name] = {matches: count, seconds: times, median_seconds: times.sort[1]}
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, frames: count, expression: expression,
  scope: "Same complete Ethernet/IPv4/UDP bytes, stateless VDF dissection versus validated public cBPF, three sequential samples each; file IO and worker startup excluded",
  results: results, speedup: results[:vdf][:median_seconds] / results[:cbpf][:median_seconds])
