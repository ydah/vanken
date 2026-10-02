# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "installed capture permissions" do
  before do
    skip "requires the disposable Linux installation" unless ENV["VANKEN_NETNS"] == "1" && RUBY_PLATFORM.include?("linux")
  end

  it "uses the installed root-owned helper and ignores interpreter and gem environment injection" do
    wrapper = "/usr/local/libexec/vanken/vanken-capture"
    stat = File.stat(wrapper)
    expect(stat.uid).to eq(0)
    expect(stat.mode & 0o022).to eq(0)
    expect(File.read(wrapper)).to include("/usr/bin/env -i", "/usr/local/libexec/vanken/helper")
    Dir.mktmpdir do |directory|
      marker = File.join(directory, "injected")
      injected = File.join(directory, "injected.rb")
      File.write(injected, "File.write(#{marker.dump}, 'executed')\n")
      output, errors, status = Open3.capture3({"RUBYOPT" => "-r#{injected}", "RUBYLIB" => directory,
        "GEM_HOME" => directory, "GEM_PATH" => directory, "BUNDLE_GEMFILE" => injected, "PATH" => directory},
        wrapper, "--list-interfaces")
      expect(status.success?).to be(true), errors
      expect(JSON.parse(output).map { |interface| interface.fetch("name") }).to include("vkn-host")
      expect(File.exist?(marker)).to be(false)
    end
  end
end
