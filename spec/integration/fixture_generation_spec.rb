# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "deterministic capture fixtures" do
  it "generates byte-identical fixtures on two runs with a small performance capture" do
    Dir.mktmpdir do |directory|
      destinations = %w[first second].map { |name| File.join(directory, name) }
      script = File.expand_path("../../script/generate_fixtures.rb", __dir__)
      destinations.each do |destination|
        output, status = Open3.capture2e(RbConfig.ruby, script, "--output", destination, "--performance", "12")
        expect(status.success?).to be(true), output
      end
      files = Dir.children(destinations.first).sort
      expect(files).to include("network.pcap", "network.pcapng", "tcp-analysis.pcapng", "http-split.pcapng",
        "dns.pcapng", "tls-client-hello.pcapng", "vlan.pcapng", "malformed.pcapng", "performance.pcapng")
      expect(Dir.children(destinations.last).sort).to eq(files)
      files.each do |name|
        expect(File.binread(File.join(destinations.last, name))).to eq(File.binread(File.join(destinations.first, name)))
      end
      frames = Vanken::Gateway::FileReader.new(File.join(destinations.first, "performance.pcapng"))
      expect(frames.to_a.size).to eq(12)
    ensure
      frames&.close
    end
  end
end
