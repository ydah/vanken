# frozen_string_literal: true

require "spec_helper"
require "zaniah/ui"
require "vanken/ui/actions"
require "vanken/ui/packet_source"
require "vanken/ui/filter_operations"
require "vanken/ui/navigation_operations"
require "vanken/config/messages"
require_relative "../support/packets"

RSpec.describe "Packet context menu" do
  it "operates the clicked frame even while another selection is still current" do
    type = Class.new do
      include Vanken::UI::FilterOperations
      include Vanken::UI::NavigationOperations
      attr_reader :app, :window, :document, :followed
      def initialize(app, window, document, source)
        @app, @window, @document, @packet_source = app, window, document, source
      end
      def native? = false
      def autoscroll? = false
      def coloring_enabled? = true
      def selected_number = 1
      def t(text, **values) = Vanken::Config::Messages.translate(text, language: "en", **values)
      def follow_tcp_stream(number) = @followed = number
    end
    app = Zaniah::App.new
    window = app.open_window
    doc = Vanken::App::Document.new(process_analysis: false).ingest([frame(tcp_bytes(flags: 2)), frame(tcp_bytes(seq: 101), number: 2)]).wait
    source = instance_double(Vanken::UI::PacketSource, reset: nil)
    ui = type.new(app, window, doc, source)
    Vanken::UI::Actions.install(ui)
    menu = ui.selection_menu("frame.number == 2", number: 2)
    actions = menu.items.map(&:action)
    expect(actions).to include(:context_mark_packet, :context_ignore_packet, :context_time_reference, :context_follow_tcp_stream)
    app.actions.call(:context_mark_packet)
    app.actions.call(:context_ignore_packet)
    app.actions.call(:context_time_reference)
    expect(doc.marked).to eq(Set[2])
    expect(doc.ignored).to eq(Set[2])
    expect(doc.time_references).to eq(Set[2])
    app.actions.call(:context_follow_tcp_stream)
    expect(ui.followed).to eq(doc.annotations[2][:tcp_stream])
    ui.selection_menu(nil, number: 2)
    expect(app.actions.command(:context_mark_packet).title).to eq("Unmark")
    app.actions.call(:context_mark_packet)
    expect(doc.marked).to be_empty
    expect(source).to have_received(:reset).at_least(:once)
    allow(ui).to receive(:document).and_return(nil)
    expect(window.dispatcher.available?(:context_ignore_packet)).to eq(:disabled)
    app.actions.call(:context_ignore_packet)
    expect(doc.ignored).to eq(Set[2])
  ensure
    doc&.close
    window&.close
    app&.executor&.shutdown
  end
end
