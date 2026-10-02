# frozen_string_literal: true

require "spec_helper"
require "vanken/config/messages"
require "ripper"

RSpec.describe Vanken::Config::Messages do
  it "translates either original language and keeps external protocol or error text" do
    expect(described_class.translate("開く", language: "en")).to eq("Open")
    expect(described_class.translate("Open", language: "ja")).to eq("開く")
    expect(described_class.translate("注記", language: "en")).to eq("note")
    expect(described_class.translate("warning", language: "ja")).to eq("警告")
    expect(described_class.translate("error", language: "ja")).to eq("エラー")
    expect(described_class.translate("トラフィック", language: "en")).to eq("traffic")
    expect(described_class.translate("開く", language: "ja")).to eq("開く")
    expect(described_class.translate("tcp.stream", language: "en")).to eq("tcp.stream")
    expect(described_class.translate("external dissector error", language: "ja")).to eq("external dissector error")
    expect { described_class.translate("開く", language: "de") }.to raise_error(Vanken::ConfigError)
  end

  it "interpolates counts and percentages without interpreting substituted filter expressions" do
    text = "先頭の%{count}区間を省略しています。間隔を広げると全期間を表示できます。"
    expect(described_class.translate(text, language: "en", count: 12)).to include("12 intervals")
    expect(described_class.translate("%{message} (位置 %{position})", language: "en", message: "frame.number % 2", position: 4)).to eq("frame.number % 2 (position 4)")
  end

  it "covers Japanese UI text, including dialog titles and settings options" do
    Dir[File.expand_path("../../lib/vanken/ui/*.rb", __dir__)].each do |path|
      Ripper.lex(File.read(path)).each_cons(3) do |left, text, right|
        next unless left[1] == :on_tstring_beg && text[1] == :on_tstring_content && right[1] == :on_tstring_end
        next unless text[2].match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
        key = text[2].gsub("\\n", "\n")
        expect(described_class::EN).to have_key(key), "missing translation in #{path}: #{key}"
      end
    end
  end

  it "provides nonempty English text for every dictionary entry with matching placeholders" do
    described_class::EN.each do |japanese, english|
      expect(english).not_to be_empty
      expect(english).not_to match(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
      expect(english.scan(/%\{(\w+)\}/).sort).to eq(japanese.scan(/%\{(\w+)\}/).sort)
    end
  end
end
