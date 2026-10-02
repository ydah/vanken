# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/application"

RSpec.describe Vanken::UI::CompletionProvider do
  it "offers saved expressions at the start while completing later field tokens independently" do
    preferences = double(history: ["tcp.port == 80"], bookmarks: {"Web traffic" => "tcp.port == 443"})
    provider = described_class.new(Struct.new(:document, :preferences).new(nil, preferences))
    completion = provider.complete("tcp", 3)
    expect(completion.range).to eq(0...3)
    expect(completion.items).to include({label: "Web traffic", insert_text: "tcp.port == 443"}, {label: "tcp.port == 80", insert_text: "tcp.port == 80"})
    expect(provider.complete("", 0).items).to include({label: "Web traffic", insert_text: "tcp.port == 443"})
    completion = provider.complete("udp && tcp", 10)
    expect(completion.range).to eq(7...10)
    expect(completion.items).to include({label: "tcp.port"})
    expect(completion.items).not_to include({label: "Web traffic", insert_text: "tcp.port == 443"})
  end
end
