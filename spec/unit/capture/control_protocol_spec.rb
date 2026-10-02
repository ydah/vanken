# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "vanken/capture/control_protocol"

RSpec.describe Vanken::Capture::ControlProtocol do
  it "writes independently parseable JSON Lines" do
    output = StringIO.new
    described_class.new(output).write(:warning, code: "capture_truncated", message: "line\nbreak")
    expect(output.string.lines.length).to eq(1)
    expect(described_class.parse(output.string)).to eq("v" => 1, "type" => "warning", "code" => "capture_truncated", "message" => "line\nbreak")
  end

  it "ignores logs, unsupported protocol versions, and invalid messages" do
    ["a log\n", "[]", '{"v":2,"type":"started"}', '{"v":1,"type":"unknown"}', "x" * 65_537].each do |line|
      expect(described_class.parse(line)).to be_nil
    end
  end
end
