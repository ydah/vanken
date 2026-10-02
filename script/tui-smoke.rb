# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "pty"
require "timeout"
require "open3"
require "vanken"

# Inputs travel through a real terminal and the public TUI decoder. The child
# observer records completed UI frames; it never invokes actions or feeds input.
module VankenTuiSmoke
  module Observer
    def initialize(**options)
      directory = ENV.fetch("VANKEN_TUI_SMOKE_DIRECTORY")
      preferences = Vanken::Config::Preferences.new(directory: File.join(directory, "config"))
      preferences.set("layout.width", 960)
      preferences.set("layout.height", 600)
      preferences.set("appearance.language", "ja")
      preferences.set("capture.backend", "socket") if RUBY_PLATFORM.include?("linux")
      super(**options.merge(preferences: preferences, session_parent: directory))
      frames = events = 0
      window.on_input { |_| events += 1 }
      window.on_frame do
        owner = window.dispatcher.focused&.owner
        focused = {}
        while owner
          focused[:id] ||= owner.test_id if owner.respond_to?(:test_id)
          focused[:label] ||= owner.label if owner.respond_to?(:label)
          focused[:value] ||= owner.value if owner.respond_to?(:value)
          focused[:select_label] = owner.accessibility_node(nil).label if owner.is_a?(Zaniah::UI::Select)
          owner = owner.respond_to?(:parent) ? owner.parent : nil
        end
        state = {frames: frames += 1, input_events: events, dialog: dialog_kind, focused: focused,
          filter_focused: window.dispatcher.focused == filter_field.focus_handle,
          filter: filter_field.value, filter_status: filter_field.status_kind,
          complete: document&.complete?, count: document&.count, displayed: document&.display_numbers,
          selected: selected_number, details: detail_nodes.size, time_format: preferences.get("packet_list.time_format"),
          palette_query: dialog.respond_to?(:query) ? dialog.query : nil,
          interfaces: (interface_infos || []).map { |item| item[:name] },
          capturing: capture.running?, capture_state: capture.state, source: document&.source, error: document&.error&.message}
        path = File.join(directory, "state.json")
        File.write("#{path}.tmp", JSON.generate(state))
        File.rename("#{path}.tmp", path)
      end
    end
  end

  class Scenario
    def initialize(directory, reports)
      @directory, @reports, @checks, @terminal = directory, reports, [], +"".b
    end

    def wait_for(description, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        path = File.join(@directory, "state.json")
        state = File.file?(path) ? JSON.parse(File.read(path)) : {}
        return state if yield(state)
        if @drainer && !@drainer.alive?
          ending = (@terminal.byteslice(-4000..) || @terminal).dup.force_encoding("UTF-8").scrub
          raise "TUI exited: #{ending}"
        end
        raise "#{description} timed out: #{state.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.01)
      end
    end

    def input(bytes, await: true)
      before = wait_for("UI frame") { |state| state["frames"] }.fetch("input_events", 0)
      @writer.write(bytes)
      @writer.flush
      wait_for("terminal input") { |state| state.fetch("input_events", 0) > before } if await
    end
    def paste(text) = input("\e[200~#{text}\e[201~")

    def focus_until(description)
      state = nil
      history = []
      60.times do
        state = wait_for("UI frame") { |value| value["frames"] }
        return state if yield(state)
        history << state["focused"] unless history.last == state["focused"]
        input("\t")
      end
      raise "#{description} is not reachable with Tab: #{state.inspect}; focus history: #{history.inspect}"
    end

    def run(capture_interface: nil)
      capture_path = File.join(@directory, "keyboard.pcap")
      write_capture(capture_path)
      command = [RbConfig.ruby, "--yjit", "-I", File.expand_path("../lib", __dir__), __FILE__, "--child"]
      @reader, @writer, @pid = PTY.spawn({"VANKEN_TUI_SMOKE_DIRECTORY" => @directory}, *command)
      @drainer = Thread.new do
        loop { @terminal << @reader.readpartial(4096) }
      rescue IOError, Errno::EIO
        nil
      end
      wait_for("welcome") { |state| state["frames"] && !state["interfaces"].empty? }
      input("\x0f") # Ctrl+O
      wait_for("open dialog") { |state| state["dialog"] == "path" }
      focus_until("capture path") { |state| state.dig("focused", "id") == "vk.path.input" }
      paste(capture_path)
      wait_for("path entry") { |state| state.dig("focused", "value") == capture_path }
      focus_until("open confirmation") { |state| state.dig("focused", "label") == "OK" }
      input("\r")
      wait_for("file ingestion") { |state| state["complete"] && state["count"] == 2 }
      @checks << "open"
      input("\e")
      wait_for("dismiss open dialog") { |state| state["dialog"].nil? }
      input("\e[1;3A") # Alt+Up selects the first packet.
      wait_for("packet details") { |state| state["selected"] == 1 && state["details"].positive? }
      @checks << "selection"
      focus_until("display filter") { |state| state["filter_focused"] }
      paste("tcp.port == 443")
      wait_for("valid filter") { |state| state["filter_status"] == "success" }
      input("\r")
      wait_for("filtered row") { |state| state["displayed"] == [2] }
      @checks << "filter"
      input("\e[107;6u") # Ctrl+Shift+K using CSI-u (unambiguous modifiers).
      wait_for("command palette") { |state| state["dialog"] == "command_palette" }
      paste("エポック")
      wait_for("palette query") { |state| state["palette_query"] == "エポック" }
      input("\r")
      wait_for("palette execution") { |state| state["time_format"] == "epoch" && state["dialog"].nil? }
      @checks << "command_palette"
      input("\x05") # Ctrl+E
      state = wait_for("capture options") { |value| value["dialog"] == "capture_options" }
      if capture_interface
        index = state["interfaces"].index(capture_interface) || raise("unknown capture interface")
        focus_until("interface selector") { |value| value.dig("focused", "select_label") == "インタフェース" }
        input("\r")
        input(("\e[B" * index) + "\r", await: false)
        focus_until("capture interface") { |value| value.dig("focused", "select_label") == "インタフェース" && value.dig("focused", "value") == capture_interface }
      end
      focus_until("capture stop count") { |value| value.dig("focused", "id") == "vk.capture.stop_count" }
      input("\e[H") # Home and Delete replace the default zero in the TUI editor.
      input("\e[3~")
      paste("3")
      wait_for("capture option edit") { |value| value.dig("focused", "value") == "3" }
      @checks << "capture_options"
      if capture_interface
        input("\e[H")
        input("\e[3~")
        paste("0")
        wait_for("unlimited capture") { |value| value.dig("focused", "value") == "0" }
        focus_until("capture start") { |value| value.dig("focused", "id") == "vk.capture.start" }
        input("\r")
        wait_for("capture startup") { |value| value["capture_state"] == "capturing" && value["count"].is_a?(Integer) }
        _, ping_status = Open3.capture2e("ping", "-c", "1", "-W", "1", "192.0.2.2")
        raise "test traffic failed" unless ping_status.success?
        captured = wait_for("captured packet") { |value| value.fetch("count", 0).to_i.positive? && value["source"] == "live" }
        @capture_frames = captured.fetch("count")
        input("\x05")
        wait_for("capture stopped") { |value| !value["capturing"] }
        @checks << "capture_start_stop"
        input("\x17") # Ctrl+W, discard a live capture before quitting.
        wait_for("unsaved capture") { |value| value["dialog"] == "unsaved" }
        focus_until("discard capture") { |value| value.dig("focused", "id") == "vk.unsaved.discard" }
        input("\r")
        wait_for("capture closed") { |value| value["count"].nil? }
      else
        input("\e")
        wait_for("dismiss capture options") { |value| value["dialog"].nil? }
      end
      input("\x11", await: false) # Ctrl+Q
      status = Timeout.timeout(10) { Process.wait2(@pid).last }
      @pid = nil
      raise "TUI exited with #{status.inspect}" unless status.success?
      @checks << "quit"
      {passed: true, checks: @checks, real_pty: true, backend: "tui", capture_interface: capture_interface, capture_frames: @capture_frames}
    ensure
      if @pid
        Process.kill("TERM", @pid) rescue nil
        Process.wait(@pid) rescue nil
      end
      @reader&.close
      @writer&.close
      @drainer&.join(1)
      File.binwrite(File.join(@reports, "terminal.log"), @terminal)
      state = File.join(@directory, "state.json")
      FileUtils.cp(state, File.join(@reports, "last-state.json")) if File.file?(state)
    end

    def write_capture(path)
      Vanken::Gateway::FileWriter.open(path, format: :pcap) do |writer|
        [80, 443].each_with_index do |port, index|
          bytes = ["0200000000020200000000010800"].pack("H*") +
            [0x45, 0, 40, 1, 0, 64, 6, 0, 0xc000020a, 0xc6336405].pack("CCnnnCCnNN") +
            [51514, port, 100, 0, 0x5002, 65_535, 0, 0].pack("nnNNnnnn")
          writer << Vanken::Core::Frame.new(bytes: bytes, timestamp_ns: 1_700_000_000_000_000_000 + index,
            original_length: bytes.bytesize, linktype: 1, interface: nil, direction: nil, number: index + 1)
        end
      end
    end
  end

  def self.run(reports:, capture_interface: nil)
    FileUtils.mkdir_p(reports)
    result = Dir.mktmpdir("vanken-tui-") { |directory| Scenario.new(directory, reports).run(capture_interface: capture_interface) }
    File.write(File.join(reports, "tui.json"), JSON.pretty_generate(result))
    result
  rescue StandardError => error
    File.write(File.join(reports, "tui.json"), JSON.pretty_generate(passed: false, real_pty: true, error: error.message))
    raise
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.delete("--child")
    require "vanken/ui/application"
    Vanken::UI::Application.prepend(VankenTuiSmoke::Observer)
    exit Vanken::CLI.start(["--tui", *ARGV])
  end
  reports = ENV.fetch("VANKEN_TUI_REPORTS", File.expand_path("../tmp/tui-results", __dir__))
  puts JSON.pretty_generate(VankenTuiSmoke.run(reports: reports, capture_interface: ENV["VANKEN_TUI_CAPTURE_INTERFACE"]))
end
