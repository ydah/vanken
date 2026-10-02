# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/ui/application"
require "vanken/ui/column_operations"
require_relative "../support/packets"

RSpec.describe "Custom columns in the packet window" do
  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      @ui.app.executor.drain
      return if yield
      raise "custom columns did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
  end

  before do
    @directory = Dir.mktmpdir
    @ui = Vanken::UI::Application.new(backend: :headless, preferences: Vanken::Config::Preferences.new(directory: @directory))
    @ui.extend(Vanken::UI::ColumnOperations)
    @document = Vanken::App::Document.new(process_analysis: false)
    @document.ingest([frame, frame(tcp_bytes(port: 81), number: 2)]).wait
    @ui.attach_document(@document)
    @ui.table.select(0)
    settle { @ui.selected_number == 1 && @ui.detail_nodes.any? }
  end
  after do
    @ui.close
    @document.close
    FileUtils.remove_entry_secure(@directory)
  end

  it "applies a field from the detail menu and saves width, position, visibility, and removal" do
    node = @ui.detail_nodes.flat_map(&:descendants).find { |item| item.field == "ip.ttl" }
    menu = @ui.field_menu(node)
    expect(menu.items.last.action).to eq(:context_apply_column)
    @ui.app.actions.call(:context_apply_column)
    key = :"field:ip.ttl"
    settle { @ui.packet_source.value(0, key) == "64" }
    @ui.table.resize_column(key, 240)
    @ui.table.move_column(key, 0)
    @ui.table.column_visible(key, false)
    loaded = Vanken::Config::Columns.load(directory: @directory)
    expect(loaded.table_columns.first).to include(key: key, width: 240, visible: false)
    @ui.columns_dialog
    @ui.window.tick
    inspection = Zaniah::Inspection.snapshot(@ui.window)
    expect(inspection.find(test_id: "vk.columns.field")).not_to be_nil
    expect(inspection.find(test_id: "vk.columns.width.field:ip.ttl")).not_to be_nil
    @ui.remove_column(key)
    expect(@ui.table.columns.map { |item| item[:key] }).not_to include(key)
    expect(Vanken::Config::Columns.load(directory: @directory).custom).to be_empty
  end

  it "shows a keyboard-accessible expert count and welcome traffic sparkline" do
    @document.store.append(frame(number: 3))
    @document.store.flush
    @document.publish_failure(3, RuntimeError.new("bad custom field"))
    @ui.packet_source.refresh
    @ui.window.request_frame
    @ui.window.tick
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    button = snapshot.accessibility.query(role: :button, label: "error: 1").first&.first
    expect(button).not_to be_nil
    expect(button.actions).to include(:press)
    expect(Zaniah::Accessibility.perform(@ui.window, button, :press)).to be(true)
    expect(@ui.dialog_kind).to eq(:expert_info)
    @ui.dismiss_dialog
    @ui.attach_document(nil)
    @ui.instance_variable_set(:@interface_infos, [{name: "test0", description: "test"}])
    @ui.instance_variable_set(:@interface_traffic, {rates: {"test0" => 2048}, history: {"test0" => [0, 1024, 2048]}})
    @ui.window.request_frame
    @ui.window.tick
    snapshot = Zaniah::Inspection.snapshot(@ui.window)
    expect(snapshot.find(test_id: "vk.interface.traffic.test0")).not_to be_nil
    expect(snapshot.accessibility.query(role: :image, label: "test0 traffic")).not_to be_empty
  end
end
