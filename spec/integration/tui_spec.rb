# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../script/tui-smoke" unless RUBY_PLATFORM.match?(/mingw|mswin/)

RSpec.describe "terminal packet inspection" do
  it "runs the actual --tui --smoke command in a PTY" do
    skip "PTY is not supported on Windows" if RUBY_PLATFORM.match?(/mingw|mswin/)
    Dir.mktmpdir do |directory|
      command = [RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
        File.expand_path("../../script/tui-smoke.rb", __dir__), "--child", "--smoke"]
      terminal = +""
      status = nil
      Timeout.timeout(10) do
        PTY.spawn({"VANKEN_TUI_SMOKE_DIRECTORY" => directory}, *command) do |reader, _writer, pid|
          begin
            loop { terminal << reader.readpartial(4096) }
          rescue Errno::EIO, EOFError
            nil
          end
          status = Process.wait2(pid).last
        end
      end
      expect(status.success?).to be(true), terminal
      expect(JSON.parse(File.read(File.join(directory, "state.json")))["frames"]).to be_between(1, 3)
    end
  end

  it "opens, selects, filters, uses the palette and edits capture options with only PTY keyboard input" do
    skip "PTY is not supported on Windows" if RUBY_PLATFORM.match?(/mingw|mswin/)
    Dir.mktmpdir do |directory|
      result = VankenTuiSmoke.run(reports: directory)
      expect(result).to include(passed: true, real_pty: true, backend: "tui")
      expect(result[:checks]).to eq(%w[open selection filter command_palette capture_options quit])
      terminal = File.binread(File.join(directory, "terminal.log"))
      expect(terminal).to include("\e[?1049h", "\e[?1049l")
    end
  end
end
