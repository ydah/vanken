# frozen_string_literal: true

require "spec_helper"
require "vanken/core/coloring"
require "tmpdir"
require_relative "../support/packets"

RSpec.describe Vanken::Core::Coloring::RuleSet do
  def rule(filter, enabled: true)
    {"name" => filter, "filter" => filter, "enabled" => enabled,
     "light" => {"fg" => "#12272E", "bg" => "#E4FFC7"},
     "dark" => {"fg" => "#E4FFC7", "bg" => "#25331A"}}
  end

  it "uses the first enabled match and preserves dark and high contrast colors" do
    document = Vanken::App::Document.new(process_analysis: false)
    document.ingest([frame]).wait
    fallback = rule("tcp").merge("light" => {"fg" => "#FFFFFF", "bg" => "#000000"})
    rules = described_class.new({"schema_version" => 1, "rules" => [rule("tcp", enabled: false), rule("tcp.flags.syn"), fallback]})
    expect(rules.match(document.view(1), theme: :light)).to eq(foreground: "#12272E", background: "#E4FFC7")
    expect(rules.match(document.view(1), theme: :dark)).to eq(foreground: "#E4FFC7", background: "#25331A")
    expect(rules.match(document.view(1), theme: :high_contrast)).to eq(foreground: "#E4FFC7")
    expect(rules.match(document.view(1), theme: :light)).not_to be_nil
    document.close
  end

  it "loads all thirteen defaults and round trips reordered and disabled rules" do
    defaults = described_class.defaults
    expect(defaults.rules.map(&:name)).to eq(["Bad TCP", "Malformed", "Checksum Errors", "TCP RST", "TCP SYN/FIN", "HTTP", "TLS", "DNS", "ICMP", "ARP", "Broadcast", "UDP", "TCP"])
    payload = defaults.to_h
    payload["rules"].reverse!
    payload["rules"].first["enabled"] = false
    Dir.mktmpdir do |directory|
      path = File.join(directory, "colors.yml")
      described_class.new(payload).save(path)
      expect(described_class.load(path).to_h).to eq(payload)
    end
  end

  it "rejects malformed expressions, colors, schemas, and unsafe YAML" do
    [rule("tcp &&"), rule("tcp").merge("light" => {"fg" => "url(bad)", "bg" => "#000000"}), rule("tcp").merge("enabled" => "yes")].each do |value|
      expect { described_class.new({"schema_version" => 1, "rules" => [value]}) }.to raise_error(Vanken::ConfigError)
    end
    expect { described_class.new({"schema_version" => 2, "rules" => []}) }.to raise_error(Vanken::ConfigError)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "unsafe.yml")
      File.write(path, "--- !ruby/object:Object {}")
      expect { described_class.load(path) }.to raise_error(Vanken::ConfigError)
    end
  end
end
