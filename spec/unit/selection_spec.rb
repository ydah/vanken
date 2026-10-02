# frozen_string_literal: true

require "spec_helper"
require "zaniah/ui"
require "vanken/ui/selection"
require_relative "../support/packets"

RSpec.describe Vanken::UI::Selection do
  it "records the newest selection before deferred details and ignores obsolete publications" do
    type = Class.new do
      include Vanken::UI::Selection
      attr_reader :document, :tree, :hex, :state
      def initialize(app, doc)
        @app, @document, @selection_generation = app, doc, 0
        @state = {number: 1, details: doc.details(1), bytes: doc.store.read(1).bytes}
        @tree = Zaniah::UI::TreeView.new(@state[:details]).expand("ipv4")
        @hex = Zaniah::UI::HexView.new(@state[:bytes])
      end
      def update = yield(@state)
      def selected_number = @state[:number]
      def show_error(error) = raise(error)
    end
    app = Zaniah::App.new
    pending = []
    allow(app.executor).to receive(:background) { |&job| pending << job }
    doc = Vanken::App::Document.new(process_analysis: false).ingest([frame, frame(number: 2)]).wait
    ui = type.new(app, doc)
    expect(ui.tree.expanded).to include("ipv4")
    ui.select_packet(1)
    ui.select_packet(2)
    expect(ui.selected_number).to eq(2)
    expect(ui.state[:details]).to be_empty
    expect(ui.hex.bytes).to eq("".b)
    pending.first.call
    app.executor.drain
    expect(ui.state[:details]).to be_empty
    pending.last.call
    app.executor.drain
    expect(ui.selected_number).to eq(2)
    expect(ui.state[:details]).not_to be_empty
    expect(ui.hex.bytes).to eq(doc.store.read(2).bytes)
    expect(ui.tree.expanded).to include("ipv4")
  ensure
    doc&.close
    app&.executor&.shutdown
  end
end
