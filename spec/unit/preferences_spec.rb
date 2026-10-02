# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "Safe preferences" do
  it "persists preferences and bounds file history and filters" do
    Dir.mktmpdir do |directory|
      preferences = Vanken::Config::Preferences.new(directory: directory)
      preferences.set("appearance.theme", "light")
      60.times { |i| preferences.remember_filter("frame.number == #{i}") }
      preferences.bookmark("TCP", "tcp")
      restored = Vanken::Config::Preferences.new(directory: directory)
      expect(restored.get("appearance.theme")).to eq("light")
      expect(restored.history.length).to eq(50)
      expect(restored.bookmarks).to eq("TCP" => "tcp")
      expect(File.stat(File.join(directory, "preferences.yml")).mode & 0o777).to eq(0o600)
    end
  end

  ["!ruby/object:Object {}", "schema_version: 999\nappearance: { theme: light }", "[broken"].each do |content|
    it "falls back safely for invalid configuration #{content.inspect}" do
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, "preferences.yml"), content)
        preferences = Vanken::Config::Preferences.new(directory: directory)
        expect(preferences.get("appearance.theme")).to eq("system")
        expect(preferences.warning).not_to be_nil
      end
    end
  end

  [{"analysis" => {"workers" => 0}}, {"layout" => {"columns" => [{"key" => "no", "width" => -1, "visible" => true}]}},
   {"packet_list" => {"time_precision" => "invalid"}}, {"appearance" => []}, {"history" => {}}].each do |change|
    it "rejects unsafe configuration shapes and bounded settings #{change.inspect}" do
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, "preferences.yml"), YAML.dump({"schema_version" => 1}.merge(change)))
        expect(Vanken::Config::Preferences.new(directory: directory).warning).not_to be_nil
      end
    end
  end
end
