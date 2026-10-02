# frozen_string_literal: true

require "spec_helper"
require "vanken/config/profiles"

RSpec.describe Vanken::Config::Profiles do
  it "copies profile settings while sharing recent files and window state" do
    Dir.mktmpdir do |directory|
      profiles = described_class.new(directory: directory)
      preferences = profiles.preferences
      preferences.set("appearance.theme", "dark")
      preferences.remember_file("capture.pcap")
      preferences.set("layout.width", 900)
      profiles.create("Work", copy_from: "default")
      profiles.switch("Work")
      work = profiles.preferences
      expect(work.get("appearance.theme")).to eq("dark")
      work.set("appearance.theme", "light")
      expect(work.recent_files).to eq(preferences.recent_files)
      expect(work.get("layout.width")).to eq(900)
      profiles.switch("default")
      expect(profiles.preferences.get("appearance.theme")).to eq("dark")
      expect(described_class.new(directory: directory).active).to eq("default")
      profiles.delete("Work")
      expect(profiles.names).to eq(["default"])
    end
  end

  it "rejects unsafe names and deletion of the current profile" do
    Dir.mktmpdir do |directory|
      profiles = described_class.new(directory: directory)
      ["../outside", "/tmp/outside", ".", "..", ""].each do |name|
        expect { profiles.create(name) }.to raise_error(Vanken::ConfigError)
      end
      expect { profiles.delete("default") }.to raise_error(Vanken::ConfigError)
      profiles.create("Safe")
      profiles.switch("Safe")
      expect { profiles.delete("Safe") }.to raise_error(Vanken::ConfigError)
    end
  end

  it "never overwrites an existing filesystem alias or linked profile root" do
    Dir.mktmpdir do |directory|
      profiles = described_class.new(directory: directory)
      profiles.create("Work")
      path = File.join(directory, "profiles", "Work", "preferences.yml")
      before = File.binread(path)
      if File.exist?(File.join(directory, "profiles", "work"))
        expect { profiles.create("work", copy_from: "default") }.to raise_error(Vanken::ConfigError, /already exists/)
        expect(File.binread(path)).to eq(before)
      end
      profiles.delete("Work")
      Dir.rmdir(File.join(directory, "profiles"))
      Dir.mktmpdir do |outside|
        File.symlink(outside, File.join(directory, "profiles"))
        expect { profiles.create("Escape") }.to raise_error(Vanken::ConfigError, /symlink/)
        expect(Dir.children(outside)).to be_empty
      end
    end
  end
end
