# frozen_string_literal: true

require "spec_helper"
require "vanken/config/sessions"
require_relative "../support/packets"

RSpec.describe Vanken::Config::Sessions do
  it "offers only safe sessions whose owner has stopped, then recovers complete raw frames" do
    document = nil
    Dir.mktmpdir do |parent|
      store = Vanken::Core::FrameStore.new(parent: parent)
      store.append(frame)
      store.flush
      directory = store.directory
      expect(described_class.candidates(parent: parent)).to be_empty
      store.close(remove: false)
      File.write(File.join(directory, "session.json"), JSON.generate(schema_version: 1, pid: 2_147_483_647))
      expect(described_class.candidates(parent: parent)).to eq([directory])
      expect { described_class.recover(directory, parent: parent, decode_as: ["invalid rule"]) }.to raise_error(StandardError)
      expect(described_class.candidates(parent: parent)).to eq([directory])
      File.open(File.join(directory, "frames.idx"), "ab") { |file| file.write("interrupted") }
      document = described_class.recover(directory, parent: parent).wait
      expect(document.count).to eq(1)
      expect(document.dirty?).to be(true)
      expect(described_class.candidates(parent: parent)).to be_empty
      document.close
    end
  ensure
    document&.close
  end

  it "rejects session aliases and discards a validated orphan without touching external files" do
    Dir.mktmpdir do |parent|
      store = Vanken::Core::FrameStore.new(parent: parent)
      directory = store.directory
      store.close(remove: false)
      File.write(File.join(directory, "session.json"), JSON.generate(schema_version: 1, pid: 2_147_483_647))
      File.symlink(directory, File.join(parent, "vanken-alias"))
      expect(described_class.candidates(parent: parent)).to eq([directory])
      expect { described_class.discard(File.join(parent, "vanken-alias"), parent: parent) }.to raise_error(Vanken::FileError)
      described_class.discard(directory, parent: parent)
      expect(File.exist?(directory)).to be(false)
    end
  end
end
