# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/ui/application"
require "vanken/ui/navigation_operations"
require "vanken/ui/coloring_operations"
require "vanken/app/navigation"
require_relative "../support/packets"

RSpec.describe "Packet navigation and coloring controls" do
  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      @ui.app.executor.drain
      return if yield
      raise "navigation did not settle: selected=#{@ui.selected_number}, dialog=#{@ui.dialog_kind}, error=#{@ui.instance_variable_get(:@last_error)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.001)
    end
  end

  before do
    @directory = Dir.mktmpdir
    preferences = Vanken::Config::Preferences.new(directory: @directory)
    @ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
    @ui.extend(Vanken::UI::NavigationOperations)
    @ui.extend(Vanken::UI::ColoringOperations)
    document = Vanken::App::Document.new(process_analysis: false)
    document.extend(Vanken::App::Navigation)
    document.ingest([frame, frame(tcp_bytes(flags: 24, seq: 101, payload: "GET /needle HTTP/1.1\r\nHost: example.test\r\n\r\n"), number: 2)]).wait
    @ui.attach_document(document)
    @ui.table.select(0)
    settle { @ui.selected_number == 1 }
  end

  after do
    @ui.cancel_packet_search
    @ui.close
    FileUtils.remove_entry_secure(@directory)
  end

  it "renders all four search modes, finds the next packet asynchronously, and toggles packet state" do
    @ui.find_packet
    @ui.window.tick
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    expect(snapshot.find(test_id: "vk.search.mode")).not_to be_nil
    expect(snapshot.find(test_id: "vk.search.target")).not_to be_nil
    @ui.search_packets("needle", mode: :string, target: :bytes)
    settle { @ui.selected_number == 2 }
    @ui.mark_packet
    @ui.ignore_packet
    @ui.time_reference
    expect(@ui.document.marked).to include(2)
    expect(@ui.document.ignored).to include(2)
    expect(@ui.document.time_references).to include(2)
    @ui.prev_in_conversation
    settle { @ui.selected_number == 1 }
  end

  it "provides a rule editor and reloads the saved order and colors" do
    @ui.coloring_dialog
    @ui.window.tick
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    expect(snapshot.find(test_id: "vk.coloring.filter")).not_to be_nil
    expect(snapshot.find(test_id: "vk.coloring.apply")).not_to be_nil
    rules = @ui.coloring_rules.to_h
    rules["rules"].reverse!
    rules["rules"].first["light"]["bg"] = "#010203"
    @ui.replace_coloring_rules(rules)
    @ui.reload_coloring_rules
    expect(@ui.coloring_rules.to_h).to eq(rules)
    expect(File.file?(File.join(@directory, "coloring_rules.yml"))).to be(true)
  end
end
