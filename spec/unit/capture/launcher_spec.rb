# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "vanken/capture/launcher"

RSpec.describe Vanken::Capture::Launcher do
  it "passes capture filters as one argv item and removes Ruby injection variables" do
    Dir.mktmpdir do |directory|
      script = File.join(directory, "helper.rb")
      File.write(script, 'require "json"; STDOUT.sync = true; STDOUT.puts JSON.generate(argv: ARGV, env: ENV.to_h); STDIN.read')
      launcher = described_class.new(direct_command: [RbConfig.ruby, script])
      original = ENV["RUBYOPT"]
      begin
        ENV["RUBYOPT"] = "-r/tmp/untrusted.rb"
        handle = launcher.launch(["-i", "lo", "--filter", "tcp; echo boom"], strategy: :direct)
        event = JSON.parse(handle.stdout.gets)
        expect(event["argv"]).to eq(["-i", "lo", "--filter", "tcp; echo boom"])
        expect(event["env"]).not_to have_key("RUBYOPT")
        expect(event["env"]).not_to have_key("RUBYLIB")
        expect(handle.stop(timeout: 1)).to be_a(Process::Status)
      ensure
        ENV["RUBYOPT"] = original
        handle&.stop(timeout: 1)
      end
    end
  end

  it "kills and reaps a helper that ignores stdin and TERM" do
    launcher = described_class.new(direct_command: [RbConfig.ruby, "-e", 'Signal.trap("TERM") {}; STDOUT.puts "ready"; STDOUT.flush; loop { sleep 1 }'])
    handle = launcher.launch([], strategy: :direct)
    expect(handle.stdout.gets).to eq("ready\n")
    expect(handle.stop(timeout: 0.05).termsig).to eq(Signal.list.fetch("KILL"))
    expect { Process.waitpid(handle.pid, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
  ensure
    handle&.stop(timeout: 0.05)
  end

  it "stops every process in the helper group" do
    launcher = described_class.new(direct_command: [RbConfig.ruby, "-e", 'child = fork { Signal.trap("TERM") {}; loop { sleep 1 } }; Signal.trap("TERM") {}; STDOUT.puts child; STDOUT.flush; loop { sleep 1 }'])
    handle = launcher.launch([], strategy: :direct)
    child = Integer(handle.stdout.gets)
    expect(Process.getpgid(child)).to eq(handle.pid)
    expect(handle.stop(timeout: 0.05).termsig).to eq(Signal.list.fetch("KILL"))
    expect(IO.select([handle.stdout], nil, nil, 1)).not_to be_nil
    expect(handle.stdout.read_nonblock(1, exception: false)).to be_nil
  ensure
    handle&.stop(timeout: 0.05)
    Process.kill("KILL", child) rescue nil
  end

  it "refuses to elevate a helper from a user-owned or writable path" do
    Dir.mktmpdir do |directory|
      wrapper = File.join(directory, "vanken-capture")
      File.write(wrapper, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, wrapper)
      launcher = described_class.new(wrapper: wrapper)
      expect { launcher.launch(%w[-i lo], strategy: :sudo) }.to raise_error(described_class::Unavailable, /root-owned/)
    end
  end

  it "requires explicit safe production strategies" do
    expect { described_class.new.launch([], strategy: :dev) }.to raise_error(described_class::Unavailable)
  end
end
