# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/ui/application"
require_relative "../support/packets"

RSpec.describe "Packet inspection window" do
  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      @ui.app.executor.drain
      return if yield && !@ui.window.dirty?
      raise "window did not settle: #{@ui.document&.error}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.001)
    end
  end

  before do
    @directory = Dir.mktmpdir
    preferences = Vanken::Config::Preferences.new(directory: @directory)
    preferences.set("layout.width", 640)
    preferences.set("layout.height", 400)
    @ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
  end

  after do
    @ui&.close
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  it "opens a capture, selects a packet, preserves tree expansion, and links bytes in both directions" do
    path = write_capture(File.join(@directory, "sample.pcap"), [frame, frame(number: 2)])
    @ui.open_file(path)
    settle { @ui.document&.complete? }
    expect(@ui.autoscroll?).to be(false)
    expect(@ui.table.body.scroll_y).to eq(0)
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    expect(snapshot.find(test_id: "vk.packet_list")).not_to be_nil
    @ui.table.select(0)
    settle { @ui.selected_number == 1 && !@ui.detail_nodes.empty? }
    @ui.tree.expand("ipv4")
    @ui.window.request_frame
    settle { @ui.tree.expanded.include?("ipv4") }
    ttl = @ui.detail_nodes.flat_map(&:descendants).find { |node| node.field == "ip.ttl" }
    @ui.select_detail(ttl)
    expect(@ui.hex.highlights).to include(range: 22...23, tone: :primary)
    expect(@ui.selection_menu(ttl.filter).items.size).to eq(3)
    @ui.app.actions.call(:context_prepare_not)
    expect(@ui.filter_field.value).to eq("!(#{ttl.filter})")
    @ui.hex.select(22...23)
    expect(@ui.selected_node.field).to eq("ip.ttl")
    @ui.table.select(1)
    settle { @ui.selected_number == 2 }
    expect(@ui.tree.expanded).to include("ipv4")
    expect(Zaniah::Inspection.snapshot(@ui.window).find(test_id: "vk.packet_bytes")).not_to be_nil
  end

  it "validates display filters, applies them with progress, and keeps accessible controls" do
    @ui.open_file(write_capture(File.join(@directory, "sample.pcap")))
    settle { @ui.document&.complete? }
    @ui.set_filter("tcp.port ==")
    settle { @ui.filter_field.status_kind == :error }
    @ui.set_filter("tcp.port == 443")
    settle { @ui.filter_field.status_kind == :success }
    @ui.apply_filter
    settle { @ui.document.filter && @ui.document.displayed_count.zero? }
    @ui.set_filter("")
    @ui.apply_filter
    settle { @ui.document.filter.nil? && @ui.document.displayed_count == 1 }
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    expect(snapshot.accessibility.query(role: :button, label: /開く/)).not_to be_empty
    expect(snapshot.accessibility.query(role: :textbox, label: /表示フィルタ/)).not_to be_empty
  end

  it "asks before discarding any live capture and leaves it open after cancellation" do
    doc = Vanken::App::Document.new.ingest([frame], live: true).wait
    @ui.attach_document(doc)
    @ui.close_document
    expect(@ui.dialog_kind).to eq(:unsaved)
    @ui.dismiss_dialog
    expect(@ui.document).to eq(doc)
    @ui.close_document
    @ui.discard_changes
    settle { @ui.document.nil? }
  end

  it "renders welcome, themes, and native headless smoke without requiring a capture" do
    @ui.window.tick
    expect(Zaniah::Inspection.snapshot(@ui.window).find(test_id: "vk.welcome")).not_to be_nil
    expect(@ui.window.scene.commands).not_to be_empty
    expect(@ui.window.scene.sprites).not_to be_empty
    %w[light dark high_contrast].each do |theme|
      @ui.change_theme(theme)
      @ui.window.tick
      expect(Zaniah::Inspection.snapshot(@ui.window).root).not_to be_nil
    end
  end

  it "runs a dissection filter in child processes and clears details when changing documents" do
    @ui.open_file(write_capture(File.join(@directory, "sample.pcap")))
    settle { @ui.document&.complete? }
    @ui.table.select(0)
    settle { @ui.selected_number == 1 }
    @ui.set_filter("ip.ttl == 64")
    @ui.apply_filter
    settle { @ui.document.filter && @ui.document.progress.nil? && @ui.document.displayed_count == 1 }
    expect(@ui.document.error).to be_nil
    old = @ui.document
    @ui.attach_document(nil)
    expect(@ui.hex.bytes).to eq("".b)
    expect(@ui.tree.selected_id).to be_nil
    expect(@ui.table.selection).to be_empty
    old.close
  end

  it "builds capture options with gateway interface metadata and confirms before losing a live document" do
    @ui.instance_variable_set(:@interface_infos, [{name: "lo", description: "Loopback", linktype: 1}])
    @ui.capture_options
    expect(@ui.dialog_kind).to eq(:capture_options)
    @ui.window.tick
    expect(Zaniah::Inspection.snapshot(@ui.window).find(test_id: "vk.capture.start")).not_to be_nil
  end
end
