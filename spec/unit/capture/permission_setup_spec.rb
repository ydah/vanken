# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "vanken/capture/permission_setup"

RSpec.describe Vanken::Capture::PermissionSetup do
  def root_owned_tree(directory, overrides = {})
    allow(File).to receive(:lstat).and_wrap_original do |original, path|
      stat = original.call(path)
      mode = path.start_with?("#{directory}/") ? stat.mode : stat.mode & ~0o022
      values = overrides.fetch(path, {})
      instance_double(File::Stat, uid: values.fetch(:uid, 0), mode: values.fetch(:mode, mode),
        file?: stat.file?, directory?: stat.directory?, symlink?: stat.symlink?)
    end
  end

  it "renders fixed Linux paths and clears every inherited interpreter variable" do
    setup = described_class.new(platform: :linux, ruby: "/opt/vanken/bin/ruby", gem_home: "/opt/vanken/gems")
    plan = setup.plan
    wrapper = plan.fetch("/usr/local/libexec/vanken/vanken-capture").fetch(:contents)
    expect(wrapper).to include("/usr/bin/env -i", "GEM_HOME=/opt/vanken/gems", "/opt/vanken/bin/ruby", '"$@"')
    expect(wrapper).not_to include("$RUBY", "$GEM_HOME", "SUDO_UID")
    expect(plan.fetch("/usr/share/polkit-1/actions/org.vanken.capture.policy")[:contents]).to include("/usr/local/libexec/vanken/vanken-capture", "auth_admin_keep")
    expect(plan.fetch("/usr/share/applications/vanken.desktop")[:contents]).to include("Exec=vanken %f")
  end

  it "stages the macOS daemon and group-limited device script without activating it" do
    Dir.mktmpdir do |directory|
      setup = described_class.new(platform: :darwin, root: directory)
      allow(setup).to receive(:validate_group!)
      setup.install
      plist = File.read(File.join(directory, "Library/LaunchDaemons/org.vanken.chmod-bpf.plist"))
      script = File.join(directory, "usr/local/libexec/vanken/chmod-bpf")
      expect(plist).to include("RunAtLoad", "StartInterval", "/usr/local/libexec/vanken/chmod-bpf")
      expect(File.read(script)).to include('/usr/bin/chgrp vanken "$device"', '/bin/chmod 660 "$device"')
      expect(File.stat(script).mode & 0o777).to eq(0o755)
    end
  end

  it "rejects unsafe group names, relative interpreter paths, and writable runtimes" do
    expect { described_class.new(platform: :linux, group: "vanken;id", ruby: "/bin/ruby", gem_home: "/gems") }.to raise_error(ArgumentError)
    expect { described_class.new(platform: :linux, ruby: "ruby", gem_home: "/gems") }.to raise_error(ArgumentError)
    expect { described_class.new(platform: :linux, ruby: RbConfig.ruby, gem_home: Gem.dir).validate_runtime! }.to raise_error(ArgumentError, /root-owned/)
  end

  it "refuses an installation destination redirected through a symlink" do
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, "outside"))
      File.symlink(File.join(directory, "outside"), File.join(directory, "usr"))
      setup = described_class.new(platform: :darwin, root: directory)
      allow(setup).to receive(:validate_group!)
      expect { setup.install }.to raise_error(ArgumentError, /symlink|unsafe/)
      expect(Dir.children(File.join(directory, "outside"))).to be_empty
    end
  end

  it "prints a dry-run plan without changing the destination" do
    Dir.mktmpdir do |directory|
      output = StringIO.new
      expect(described_class.run(["--platform", "darwin", "--root", directory, "--dry-run"], stdout: output, stderr: StringIO.new)).to eq(0)
      expect(JSON.parse(output.string).fetch("files")).to include("/Library/LaunchDaemons/org.vanken.chmod-bpf.plist")
      expect(Dir.children(directory)).to be_empty
    end
  end

  it "stages the fixed Linux wrapper and packaged helper without trusting or executing them" do
    Dir.mktmpdir do |directory|
      setup = described_class.new(platform: :linux, ruby: "/opt/vanken/bin/ruby", gem_home: "/opt/vanken/gems", root: directory)
      setup.install
      prefix = File.join(directory, "usr/local/libexec/vanken")
      expect(File.read(File.join(prefix, "helper"))).to include('require "vanken/capture/helper_main"')
      expect(File.read(File.join(prefix, "vanken-capture"))).to include("/opt/vanken/bin/ruby")
      expect(File.file?(File.join(prefix, "lib/vanken/capture/helper_options.rb"))).to be(true)
      expect(File.stat(File.join(prefix, "vanken-capture")).mode & 0o777).to eq(0o755)
    end
  end

  it "trusts root-owned runtime aliases and traverses a linked directory's actual contents" do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      runtime = File.join(directory, "runtime")
      FileUtils.mkdir_p(runtime)
      library = File.join(runtime, "libruby.so.3.4.11")
      File.write(library, "library")
      File.symlink("libruby.so.3.4.11", File.join(runtime, "libruby.so"))
      manuals = File.join(directory, "manuals")
      FileUtils.mkdir_p(manuals)
      manual = File.join(manuals, "ruby.1")
      File.write(manual, "manual")
      File.symlink(manuals, File.join(runtime, "man"))
      root_owned_tree(directory)
      setup = described_class.new(platform: :linux, ruby: "/opt/ruby", gem_home: "/opt/gems")
      expect { setup.send(:trusted_tree!, runtime) }.not_to raise_error
      expect(File).to have_received(:lstat).with(manual)
    end
  end

  it "rejects writable targets, user-owned intermediate aliases and unsafe linked-directory contents" do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      target = File.join(directory, "target")
      File.write(target, "library")
      alias_path = File.join(directory, "alias")
      link = File.join(directory, "libruby.so")
      File.symlink(target, alias_path)
      File.symlink(alias_path, link)
      overrides = {target => {mode: 0o100666}}
      root_owned_tree(directory, overrides)
      setup = described_class.new(platform: :linux, ruby: "/opt/ruby", gem_home: "/opt/gems")
      expect { setup.send(:trusted_tree!, link) }.to raise_error(ArgumentError, /root-owned|writable/)
      overrides.replace(alias_path => {uid: 1000})
      expect { setup.send(:trusted_tree!, link) }.to raise_error(ArgumentError, /root-owned/)
      linked_directory = File.join(directory, "linked-directory")
      File.symlink(directory, linked_directory)
      overrides.replace(target => {uid: 1000})
      expect { setup.send(:trusted_tree!, linked_directory) }.to raise_error(ArgumentError, /root-owned/)
    end
  end

  it "rejects broken and cyclic runtime aliases" do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      broken = File.join(directory, "broken")
      File.symlink("missing", broken)
      cycle = File.join(directory, "cycle")
      File.symlink("cycle", cycle)
      root_owned_tree(directory)
      setup = described_class.new(platform: :linux, ruby: "/opt/ruby", gem_home: "/opt/gems")
      [broken, cycle].each do |path|
        expect { setup.send(:trusted_tree!, path) }.to raise_error(ArgumentError)
      end
    end
  end

  it "checks the actual runtime tree when the interpreter is reached through an alias" do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      launcher = File.join(directory, "launcher")
      runtime = File.join(directory, "runtime")
      libraries = File.join(runtime, "lib/ruby")
      gems = File.join(directory, "gems")
      source = File.join(directory, "source")
      FileUtils.mkdir_p([File.join(launcher, "bin"), File.join(runtime, "bin"), libraries, gems, source])
      interpreter = File.join(runtime, "bin/ruby")
      File.write(interpreter, "interpreter")
      File.chmod(0o755, interpreter)
      ruby_alias = File.join(launcher, "bin/ruby")
      File.symlink(interpreter, ruby_alias)
      writable_library = File.join(runtime, "lib/libruby.so")
      File.write(writable_library, "library")
      root_owned_tree(directory, writable_library => {mode: 0o100666})
      stub_const("Vanken::Capture::PermissionSetup::SOURCE", source)
      allow(Open3).to receive(:capture2).and_return(["#{libraries}\n", instance_double(Process::Status, success?: true)])
      setup = described_class.new(platform: :linux, ruby: ruby_alias, gem_home: gems)
      expect { setup.validate_runtime! }.to raise_error(ArgumentError, /root-owned/)
    end
  end

  it "rejects writable intermediate paths even when a link's .. resolves to a safe target" do
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      File.write(File.join(directory, "target"), "library")
      untrusted = File.join(directory, "untrusted")
      Dir.mkdir(untrusted)
      File.chmod(0o777, untrusted)
      link = File.join(directory, "alias")
      File.symlink("untrusted/../target", link)
      root_owned_tree(directory)
      setup = described_class.new(platform: :linux, ruby: "/opt/ruby", gem_home: "/opt/gems")
      expect { setup.send(:trusted_tree!, link) }.to raise_error(ArgumentError, /root-owned/)
    end
  end

  it "refuses source library directory links instead of silently installing an incomplete helper" do
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p([File.join(directory, "lib"), File.join(directory, "exe"), File.join(directory, "target")])
      File.write(File.join(directory, "exe/vanken-capture"), "helper")
      File.symlink(File.join(directory, "target"), File.join(directory, "lib/alias"))
      stub_const("Vanken::Capture::PermissionSetup::SOURCE", directory)
      setup = described_class.new(platform: :linux, ruby: "/opt/ruby", gem_home: "/opt/gems")
      allow(setup).to receive(:asset).and_return(contents: "asset", mode: 0o644)
      expect { setup.plan }.to raise_error(ArgumentError, /source library contains a symlink/)
    end
  end
end
