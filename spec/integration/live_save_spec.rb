# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "timeout"
require_relative "../support/packets"

RSpec.describe "Saving an active acquisition" do
  it "waits for the save without waiting for acquisition EOF" do
    source = Class.new do
      def initialize(frame) = @frame = frame
      def next_frame(timeout:)
        if @frame
          result, @frame = @frame, nil
          result
        else
          sleep(timeout)
          nil
        end
      end
      def eof? = !!@stopped
      def stop = @stopped = true
    end.new(frame)
    document = Vanken::App::Document.new.ingest(source, live: true)
    Timeout.timeout(2) { sleep(0.001) until document.count == 1 }
    Dir.mktmpdir do |directory|
      path = File.join(directory, "live.pcapng")
      document.save(path).wait_for_save(2)
      expect(document.loading?).to be(true)
      expect(document.error).to be_nil
      reader = Vanken::Gateway::FileReader.new(path)
      expect(reader.next_frame.bytes).to eq(frame.bytes)
      reader.close
    end
  ensure
    document&.close
  end
end
