# frozen_string_literal: true

require "spec_helper"
require "zaniah/ui"
require "vanken/ui/actions"
require "vanken/config/messages"

RSpec.describe Vanken::UI::Actions do
  it "accepts dispatcher contexts for enabled and checked commands and uses terminal modifiers" do
    ui_class = Struct.new(:app, :window, :document) do
      attr_reader :marked
      def native? = false
      def autoscroll? = true
      def coloring_enabled? = true
      def t(text, **values) = Vanken::Config::Messages.translate(text, language: "en", **values)
      def mark_packet = @marked = true
    end
    app = Zaniah::App.new
    window = app.open_window
    ui = ui_class.new(app, window, Object.new)
    described_class.install(ui)
    expect(window.dispatcher.available?(:mark_packet)).to eq(:enabled)
    expect(window.dispatcher.perform(:mark_packet)).to be_truthy
    expect(ui.marked).to be(true)
    expect(app.actions.command(:autoscroll).checked.call(Object.new)).to be(true)
    expect(app.actions.command(:toggle_coloring).checked.call(Object.new)).to be(true)
    ui.document = nil
    expect(window.dispatcher.available?(:mark_packet)).to eq(:disabled)
    expect(window.dispatcher.keymap.shortcut_for(:open)).to eq("ctrl-o")
  ensure
    window&.close
    app&.executor&.shutdown
  end
end
