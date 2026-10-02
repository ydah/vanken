# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "Command line" do
  it "prints version and help without opening a window" do
    out = StringIO.new
    expect(Vanken::CLI.start(["--version"], out: out)).to eq(0)
    expect(out.string).to eq("#{Vanken::VERSION}\n")
    expect(Vanken::CLI.start(["--help"], out: out)).to eq(0)
    expect(out.string).to include("--headless", "--tui", "--read")
  end

  it "prints filtered packet columns without a graphical backend" do
    Dir.mktmpdir do |directory|
      input = write_capture(File.join(directory, "capture.pcap"))
      out, err = StringIO.new, StringIO.new
      expect(Vanken::CLI.start(["--headless", "--read", input, "--print-columns", "--filter", "tcp.port == 80"], out: out, err: err)).to eq(0)
      expect(out.string).to include("192.0.2.10", "198.51.100.5", "TCP")
      expect(err.string).to eq("")
    end
  end

  it "reports invalid options and corrupt files without a traceback" do
    err = StringIO.new
    expect(Vanken::CLI.start(["--unknown"], err: err)).to eq(2)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "corrupt.pcap")
      File.write(path, "invalid")
      expect(Vanken::CLI.start(["--headless", "--read", path, "--print-columns"], err: err)).to eq(1)
    end
    expect(err.string).not_to include(".rb:")
  end
end
