# frozen_string_literal: true

require "spec_helper"
require "objspace"

RSpec.describe Vanken::Capture::AnalyzerWire do
  it "receives fragmented binary messages without growing the payload allocation beyond its length" do
    reader, writer = IO.pipe
    bytes = "\x00\xff".b * (512 << 10)
    sender = Thread.new { writer.write(bytes); writer.close }
    result = described_class.exact(reader, bytes.bytesize, nil)
    sender.join
    expect(result).to eq(bytes)
    expect(ObjectSpace.memsize_of(result)).to be < (bytes.bytesize * 1.1)
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    sender&.join
  end
end
