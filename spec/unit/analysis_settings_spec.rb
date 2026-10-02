# frozen_string_literal: true

require "spec_helper"
require "vanken/config/analysis_settings"

RSpec.describe Vanken::Config::AnalysisSettings do
  it "persists Decode As and enables only explicitly trusted plugin files" do
    Dir.mktmpdir do |directory|
      settings = described_class.new(directory: directory)
      settings.decode_as = ["udp.port==8443,dns"]
      plugin = File.join(directory, "example.rb")
      File.write(plugin, "raise 'must not be loaded by configuration'\n")
      settings.register_plugin(plugin)
      expect(settings.plugins).to be_empty
      expect(settings.untrusted_plugins).to eq([plugin])
      settings.trust_plugins([plugin])
      restored = described_class.new(directory: directory)
      expect(restored.decode_as).to eq(["udp.port==8443,dns"])
      expect(restored.plugins).to eq([plugin])
      expect(File.stat(File.join(directory, "plugins.yml")).mode & 0o777).to eq(0o600)
    end
  end

  it "rejects object YAML, malformed rules, and unregistered trust changes" do
    Dir.mktmpdir do |directory|
      settings = described_class.new(directory: directory)
      expect { settings.decode_as = ["not-a-decode-rule"] }.to raise_error(Vanken::ConfigError)
      expect { settings.trust_plugins(["outside.rb"]) }.to raise_error(Vanken::ConfigError)
      File.write(File.join(directory, "decode_as.yml"), "!ruby/object:Object {}")
      expect { described_class.new(directory: directory).decode_as }.to raise_error(Vanken::ConfigError)
    end
  end
end
