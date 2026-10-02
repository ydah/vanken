# frozen_string_literal: true

require "spec_helper"
require "zaniah"
require "zaniah/task"
require_relative "../support/packets"

RSpec.describe "Sorting a running filter" do
  it "waits for the complete filter result and preserves all matching frames" do
    submitted = Queue.new
    scanner = ->(*) do
      task = Zaniah::Task.new
      submitted << task
      task
    end
    document = Vanken::App::Document.new(scanner: scanner).ingest([frame, frame(number: 2)]).wait
    document.apply_filter("ip.ttl == 64")
    task = submitted.pop
    document.sort(:no, :desc)
    task.resolve({"matches" => [1, 2]})
    document.wait(2)
    expect(document.display_numbers).to eq([2, 1])
    expect(document.filter.expression).to eq("ip.ttl == 64")
    expect(document.error).to be_nil
  ensure
    document&.close
  end
end
