# frozen_string_literal: true

require "spec_helper"
require_relative "../support/packets"

RSpec.describe "Plugin registry isolation" do
  def plugin_source(name = "Example protocol", label = "Example id")
    <<~RUBY
      class Example < Redhound::Dissector
        protocol :example, name: #{name.inspect}, short: "EXAMPLE"
        dissects_on "udp.port", 9999
        header do
          uint16 :message_id, "example.id"
          uint8 :kind, "example.kind"
        end
        def summary(layer) = "#{label} \#{layer[:message_id]}"
      end
    RUBY
  end

  def example_frame
    payload = [42, 1].pack("nC")
    udp = [51514, 9999, payload.bytesize + 8, 0].pack("n4") + payload
    ip = [0x45, 0, 20 + udp.bytesize, 1, 0, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
    frame(["0200000000020200000000010800"].pack("H*") + ip + udp)
  end

  it "supports the public custom-dissector API, scoped detail headings, summaries, and filter completion" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, plugin_source)
      dissector = Vanken::Gateway::Dissector.new(plugins: [path])
      packet = dissector.dissect(example_frame)
      expect(packet.values("example.id")).to eq([42])
      expect(packet.columns[:protocol]).to eq("EXAMPLE")
      expect(packet.info).to include("Example id 42")
      expect(Vanken::Gateway::DetailBuilder.new.build(packet).find { |node| node.id == "example" }.label).to eq("Example protocol")
      catalog = Vanken::Gateway::FieldCatalog.new(registry: dissector.registry)
      expect(catalog.protocol?("example")).to be(true)
      expect(catalog.names).to include("example", "example.id")
      expect(Vanken::Core::DisplayFilter.compile("example && example.id == 42", catalog: catalog).match?(packet)).to be(true)
      expect(Redhound::Registry.default.protocols).not_to have_key(:example)
      expect(Redhound::Registry.default.lookup("udp.port", 9999)).to be_nil
      expect(Object.const_defined?(:Example, false)).to be(false)
    end
  end

  it "does not alter existing sessions when a plugin is removed or its same class is reloaded" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, plugin_source)
      previous = Vanken::Gateway::Dissector.new(plugins: [path])
      File.write(path, plugin_source("Updated protocol", "Updated id"))
      current = Vanken::Gateway::Dissector.new(plugins: [path])
      expect(previous.dissect(example_frame).info).to include("Example id 42")
      expect(current.dissect(example_frame).info).to include("Updated id 42")
      expect(previous.registry.protocols[:example]).not_to equal(current.registry.protocols[:example])
      expect(Vanken::Gateway::Dissector.new.dissect(example_frame).layer?("example")).to be(false)
    end
  end

  it "restores the active registry after missing files and syntax errors" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "bad.rb")
      File.write(path, "this is invalid (")
      expect { Vanken::Gateway::Dissector.new(plugins: [path]) }.to raise_error(Vanken::ConfigError) { |error| expect(error.cause).to be_a(SyntaxError) }
      expect { Vanken::Gateway::Dissector.new(plugins: [File.join(directory, "missing.rb")]) }.to raise_error(Vanken::ConfigError) { |error| expect(error.cause).to be_a(LoadError) }
      expect(Thread.current[:vanken_registry]).to be_nil
      expect(Vanken::Gateway::Dissector.new.registry.protocols).not_to have_key(:example)
    end
  end

  it "restores an enclosing registry even when nested plugin work fails" do
    default = Redhound::Registry.default
    outer, inner = default.copy, default.copy
    Vanken::Gateway::RegistryScope.with(outer) do
      expect(Redhound::Registry.default).to equal(outer)
      expect do
        Vanken::Gateway::RegistryScope.with(inner) do
          expect(Redhound::Registry.default).to equal(inner)
          raise Vanken::ConfigError, "nested failure"
        end
      end.to raise_error(Vanken::ConfigError)
      expect(Redhound::Registry.default).to equal(outer)
    end
    expect(Redhound::Registry.default).to equal(default)
    expect(Thread.current[:vanken_registry]).to be_nil
  end

  it "rebuilds document columns and worker filters after plugin removal and reloading" do
    document = nil
    Dir.mktmpdir do |directory|
      path = File.join(directory, "example.rb")
      File.write(path, plugin_source)
      document = Vanken::App::Document.new(plugins: [path]).ingest([example_frame]).wait
      expect(document.error).to be_nil
      expect(document.row(1)[:protocol]).to eq("EXAMPLE")
      document.apply_filter("example.id == 42").wait
      expect(document.display_numbers).to eq([1])
      document.apply_filter("").wait
      document.reanalyze(plugins: []).wait
      expect(document.row(1)[:protocol]).to eq("UDP")
      expect(document.catalog.protocol?("example")).to be(false)
      File.write(path, plugin_source("Reloaded protocol", "Reloaded id"))
      document.reanalyze(plugins: [path]).wait
      expect(document.row(1)[:protocol]).to eq("EXAMPLE")
      expect(document.row(1)[:info]).to include("Reloaded id 42")
      expect(document.details(1).find { |node| node.id == "example" }.label).to eq("Reloaded protocol")
      require "vanken/capture/filter_worker"
      expect(Vanken::Capture::FilterWorker.call(document.filter_payload(1, 2, expression: "example"))["matches"]).to eq([1])
      expect(Redhound::Registry.default.protocols).not_to have_key(:example)
    end
  ensure
    document&.close
  end

  it "keeps concurrent plugin registration within each thread's session" do
    Dir.mktmpdir do |directory|
      entered, release = Queue.new, Queue.new
      threads = %i[alpha_plugin beta_plugin].map do |name|
        path = File.join(directory, "#{name}.rb")
        File.write(path, <<~RUBY)
          Class.new(Redhound::Dissector) { protocol :#{name}, name: "#{name}", short: "TEST" }
          Thread.current[:vanken_plugin_barriers].first << true
          Thread.current[:vanken_plugin_barriers].last.pop
        RUBY
        Thread.new do
          Thread.current[:vanken_plugin_barriers] = [entered, release]
          Vanken::Gateway::Dissector.new(plugins: [path])
        end
      end
      2.times { entered.pop }
      expect(Redhound::Registry.default.protocols.keys).not_to include(:alpha_plugin, :beta_plugin)
      2.times { release << true }
      alpha, beta = threads.map(&:value)
      expect(alpha.registry.protocols).to have_key(:alpha_plugin)
      expect(alpha.registry.protocols).not_to have_key(:beta_plugin)
      expect(beta.registry.protocols).to have_key(:beta_plugin)
      expect(beta.registry.protocols).not_to have_key(:alpha_plugin)
    ensure
      2.times { release << true } if release
      threads&.each { |thread| thread.join(1) }
    end
  end
end
