# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/config/columns"

RSpec.describe Vanken::Config::Columns do
  it "migrates builtin layout settings and roundtrips custom columns privately" do
    Dir.mktmpdir do |directory|
      settings = described_class.load(directory: directory, legacy: [{"key" => "info", "width" => 320, "visible" => false}])
      expect(settings.table_columns.first).to include(key: :info, width: 320, visible: false)
      key = settings.add("ip.ttl", label: "TTL", width: 80)
      settings.move(key, 0)
      settings.save(directory)
      loaded = described_class.load(directory: directory)
      expect(loaded.to_h).to eq(settings.to_h)
      expect(loaded.table_columns.first).to include(key: :"field:ip.ttl", label: "TTL", width: 80)
      expect(File.stat(File.join(directory, "columns.yml")).mode & 0o777).to eq(0o600)
      loaded.remove(key)
      expect(loaded.custom).to be_empty
    end
  end

  it "validates keys, widths, field names, and schema without changing good settings" do
    settings = described_class.new
    before = settings.to_h
    ["ip.ttl;system('bad')", "", "x" * 300].each { |field| expect { settings.add(field) }.to raise_error(Vanken::ConfigError) }
    expect { settings.add("ip.ttl", width: Float::INFINITY) }.to raise_error(Vanken::ConfigError)
    expect(settings.to_h).to eq(before)
    expect { described_class.new({"schema_version" => 2, "columns" => []}) }.to raise_error(Vanken::ConfigError)
    expect { settings.update_layout([{key: :no, width: -1, visible: true}]) }.to raise_error(Vanken::ConfigError)
    expect(settings.to_h).to eq(before)
  end

  it "does not follow a symlink configuration file" do
    Dir.mktmpdir do |directory|
      target = File.join(directory, "other.yml")
      Vanken::Config::YamlFile.write(target, described_class.new.to_h)
      File.symlink(target, File.join(directory, "columns.yml"))
      expect { described_class.load(directory: directory) }.to raise_error(Vanken::ConfigError)
    end
  end
end
