# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/application"
require "timeout"
require_relative "../support/packets"

RSpec.describe "Settings and interrupted captures" do
  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      @ui.app.executor.drain
      return if yield && !@ui.window.dirty?
      raise "window did not settle: #{@ui.document&.error}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.001)
    end
  end

  after { @ui&.close }

  it "reopens the current settings in the selected language and preserves packet selection" do
    Dir.mktmpdir do |directory|
      preferences = Vanken::Config::Preferences.new(directory: directory)
      preferences.set("appearance.language", "ja")
      preferences.set("layout.width", 640)
      preferences.set("layout.height", 480)
      @ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences)
      dns = [0x1234, 0x0100, 0, 0, 0, 0].pack("n6")
      udp = [51514, 8443, dns.bytesize + 8, 0].pack("n4") + dns
      ip = [0x45, 0, 20 + udp.bytesize, 1, 0, 64, 17, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN")
      bytes = ["0200000000020200000000010800"].pack("H*") + ip + udp
      doc = Vanken::App::Document.new.ingest([frame(bytes), frame(bytes, number: 2)]).wait
      @ui.attach_document(doc)
      @ui.select_packet(1)
      settle { @ui.selected_number == 1 && !@ui.detail_nodes.empty? }
      @ui.preferences_dialog
      @ui.apply_preference("appearance.language", "en")
      settle { @ui.dialog_kind == :preferences }
      snapshot = Zaniah::Inspection.snapshot(@ui.window)
      expect(snapshot.accessibility.query(role: :dialog, label: "Preferences")).not_to be_empty
      expect(snapshot.accessibility.query(role: :button, label: "Manage profiles")).not_to be_empty
      expect(@ui.table.selection).to include(1)
      expect(@ui.tree).not_to be_nil
      @ui.dismiss_dialog
      entered, release = Queue.new, Queue.new
      first = true
      allow(doc).to receive(:reanalyze).and_wrap_original do |operation, **options|
        if first
          first = false
          entered << true
          release.pop
        end
        operation.call(**options)
      end
      @ui.analysis_settings.decode_as = ["udp.port==8443,dns"]
      begin
        @ui.reconfigure_analysis
        Timeout.timeout(5) { entered.pop }
        settle { @ui.packet_source.value(0, :protocol) == "UDP" }
        @ui.select_packet(2)
        @ui.apply_preference("analysis.max_flows", 2_000)
      ensure
        release << true
      end
      settle { doc.complete? && doc.analysis_options[:max_flows] == 2_000 && @ui.selected_number == 2 && @ui.packet_source.value(0, :protocol) == "DNS" }
      expect(doc.count).to eq(2)
      expect(doc.error).to be_nil
      expect(@ui.selected_number).to eq(2)
      @ui.close
    end
  end

  it "detects an orphan at startup and recovers it as an unsaved capture" do
    Dir.mktmpdir do |directory|
      sessions = File.join(directory, "sessions")
      Dir.mkdir(sessions)
      store = Vanken::Core::FrameStore.new(parent: sessions)
      store.append(frame)
      store.flush
      spool = store.directory
      store.close(remove: false)
      File.write(File.join(spool, "session.json"), JSON.generate(schema_version: 1, pid: 2_147_483_647))
      preferences = Vanken::Config::Preferences.new(directory: File.join(directory, "config"))
      preferences.set("layout.width", 640)
      preferences.set("layout.height", 480)
      @ui = Vanken::UI::Application.new(backend: :headless, preferences: preferences, session_parent: sessions)
      settle { @ui.dialog_kind == :recovery }
      @ui.recover_session(spool)
      settle { @ui.document&.complete? }
      expect(@ui.document.count).to eq(1)
      expect(@ui.document.dirty?).to be(true)
      expect(@ui.document.store.read(1).bytes).to eq(frame.bytes)
      @ui.close
    end
  end
end
