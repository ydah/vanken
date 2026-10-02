# frozen_string_literal: true

require "tmpdir"
require "vanken/ui/application"
require_relative "../script/generate_fixtures"

# Only synthetic traffic and documentation addresses appear in this screenshot.
RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
Dir.mktmpdir("vanken-overview-") do |directory|
  preferences = Vanken::Config::Preferences.new(directory: directory)
  preferences.set("appearance.language", "en")
  preferences.set("appearance.theme", "dark")
  preferences.set("layout.width", 1280)
  preferences.set("layout.height", 800)
  ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
  packets = [VankenFixtures.arp, VankenFixtures.arp(reverse: true),
    *VankenFixtures.dns, *VankenFixtures.http_split, *VankenFixtures.tls_client_hello,
    VankenFixtures.icmp, VankenFixtures.icmp(reverse: true)]
  frames = packets.each_with_index.map do |bytes, index|
    Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: VankenFixtures::TIMESTAMP_NS + (index * 1_000_000),
      original_length: bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
  end
  document = Vanken::App::Document.new(preferences: preferences, process_analysis: false).ingest(frames).wait(10)
  raise document.error if document.error
  ui.attach_document(document)
  # Build the scene while selection loads; rasterize the finished scene once.
  render = ui.window.method(:render)
  ui.window.define_singleton_method(:render) { |element, **options| render.call(element, **options, present: false) }
  ui.window.tick
  ui.table.select(7)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until ui.detail_nodes.any? && frames.each_index.all? { |index| ui.packet_source.value(index, :protocol) }
    raise "Packet selection timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    ui.app.executor.drain
    sleep(0.005)
  end
  ui.tree.expand("ipv4")
  ipv4 = ui.detail_nodes.find { |node| node.id == "ipv4" }
  raise "IPv4 details missing" unless ipv4
  ui.tree.select_id(ipv4.id)
  ui.select_detail(ipv4)
  ui.window.define_singleton_method(:render, render)
  ui.window.request_frame
  ui.window.tick
  output = File.expand_path("../docs/media/overview.png", __dir__)
  FileUtils.mkdir_p(File.dirname(output))
  ui.window.device.write_png(output)
  puts output
ensure
  ui&.close
end
