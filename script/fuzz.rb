# frozen_string_literal: true

require "vanken"

random = Random.new(Integer(ENV.fetch("SEED", "314159")))
count = Integer(ENV.fetch("CASES", "5000"))
alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789.!<>=&|(){}:,"\\ '.chars
dissector = Vanken::Gateway::Dissector.new
count.times do |index|
  expression = Array.new(random.rand(0..256)) { alphabet.sample(random: random) }.join
  begin
    Vanken::Core::DisplayFilter.compile(expression)
  rescue Vanken::Core::DisplayFilter::SyntaxError
    # Invalid expressions must end in a bounded syntax error.
  end
  bytes = random.bytes(random.rand(0..512))
  frame = Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: 0, original_length: bytes.bytesize,
    linktype: 1, interface: nil, direction: nil, number: index + 1)
  begin
    packet = dissector.dissect(frame)
    Vanken::Gateway::DetailBuilder.new.build(packet)
  rescue Vanken::FileError
    # Malformed captures are allowed to fail at the Gateway boundary.
  end
end
puts "#{count} deterministic filter and packet fuzz cases passed"
