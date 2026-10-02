# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe "Private spool boundaries" do
  it "rejects symlinks before changing any target permissions or contents" do
    Dir.mktmpdir do |directory|
      target = File.join(directory, "target")
      File.write(target, "keep", mode: "w", perm: 0o644)
      spool = File.join(directory, "spool")
      Dir.mkdir(spool)
      File.symlink(target, File.join(spool, "session.json"))
      expect { Vanken::Core::FrameStore.new(directory: spool) }.to raise_error(Vanken::FileError)
      expect(File.read(target)).to eq("keep")
      expect(File.stat(target).mode & 0o777).to eq(0o644)
    end
  end

  it "interns repeated interface hashes once regardless of key representation" do
    store = Vanken::Core::FrameStore.new
    3.times { |number| store.append(frame(number: number + 1).with(interface: {name: "lo"})) }
    store.append(frame(number: 4).with(interface: {"name" => "lo"}))
    store.flush
    expect(store.interfaces.size).to eq(1)
    expect(store.read(4).interface).to eq("name" => "lo")
  ensure
    store&.close
  end
end
