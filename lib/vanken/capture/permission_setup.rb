# frozen_string_literal: true

require "optparse"
require "json"
require "etc"
require "shellwords"
require "tempfile"
require "open3"

module Vanken
  module Capture
    class PermissionSetup
      PREFIX = "/usr/local/libexec/vanken"
      SOURCE = File.expand_path("../../..", __dir__)

      def self.run(argv, stdout: $stdout, stderr: $stderr)
        options = {}
        dry_run = false
        parser = OptionParser.new do |flags|
          flags.banner = "Usage: vanken-setup-permissions [--dry-run] [--ruby PATH --gem-home PATH] [--policy polkit|sudoers] [--group GROUP]"
          flags.on("--platform VALUE", %w[linux darwin]) { |value| options[:platform] = value.to_sym }
          flags.on("--ruby PATH") { |value| options[:ruby] = value }
          flags.on("--gem-home PATH") { |value| options[:gem_home] = value }
          flags.on("--policy VALUE", %w[polkit sudoers]) { |value| options[:policy] = value.to_sym }
          flags.on("--group GROUP") { |value| options[:group] = value }
          flags.on("--root DIRECTORY", "Stage files without activating system permissions") { |value| options[:root] = value }
          flags.on("--dry-run") { dry_run = true }
          flags.on("-h", "--help") { stdout.puts(flags); return 0 }
        end
        known = %w[--platform --ruby --gem-home --policy --group --root --dry-run --help]
        argv.each do |value|
          raise ArgumentError, "unknown option: #{value}" if value.start_with?("--") && !known.include?(value.split("=", 2).first)
        end
        remaining = parser.parse(argv.dup)
        raise ArgumentError, "unexpected arguments: #{remaining.join(' ')}" unless remaining.empty?
        setup = new(**options)
        setup.install unless dry_run
        stdout.puts(JSON.pretty_generate(platform: setup.platform, dry_run: dry_run, staged: setup.staged?,
          files: setup.plan.keys, next_steps: setup.next_steps))
        0
      rescue ArgumentError, OptionParser::ParseError => error
        stderr.puts(error.message)
        2
      rescue SystemCallError, IOError => error
        stderr.puts(error.message)
        1
      end

      attr_reader :platform

      def initialize(platform: nil,
                     ruby: nil, gem_home: nil, policy: :polkit, group: "vanken", root: "/")
        platform ||= RUBY_PLATFORM.include?("darwin") ? :darwin : (RUBY_PLATFORM.include?("linux") ? :linux : :unsupported)
        @platform, @ruby, @gem_home, @policy, @group = platform.to_sym, ruby, gem_home, policy.to_sym, group
        raise ArgumentError, "unsupported platform" unless %i[linux darwin].include?(@platform)
        raise ArgumentError, "invalid policy" unless %i[polkit sudoers].include?(@policy)
        raise ArgumentError, "invalid capture group" unless @group.match?(/\A[a-z_][a-z0-9_-]{0,31}\z/)
        if @platform == :linux
          [@ruby, @gem_home].each do |path|
            raise ArgumentError, "Linux setup requires absolute --ruby and --gem-home paths" unless path&.start_with?("/") && !path.include?("\n")
          end
        end
        raise ArgumentError, "staging root must be an existing absolute directory" unless root.start_with?("/") && File.directory?(root) && !File.symlink?(root)
        @root = File.realpath(root)
      end

      def staged? = @root != "/"

      def plan
        if @platform == :darwin
          return {"#{PREFIX}/chmod-bpf" => asset("macos/chmod-bpf", mode: 0o755),
                  "/Library/LaunchDaemons/org.vanken.chmod-bpf.plist" => asset("macos/org.vanken.chmod-bpf.plist")}
        end
        files = {"#{PREFIX}/vanken-capture" => asset("linux/vanken-capture.wrapper", mode: 0o755),
                 "#{PREFIX}/helper" => {contents: File.binread(File.join(SOURCE, "exe/vanken-capture")), mode: 0o755},
                 "/usr/share/applications/vanken.desktop" => asset("linux/vanken.desktop")}
        if @policy == :polkit
          files["/usr/share/polkit-1/actions/org.vanken.capture.policy"] = asset("linux/org.vanken.capture.policy")
        else
          files["/etc/sudoers.d/vanken"] = asset("linux/vanken.sudoers", mode: 0o440)
        end
        Dir.glob(File.join(SOURCE, "lib", "**", "*"), File::FNM_DOTMATCH).each do |path|
          raise ArgumentError, "source library contains a symlink" if File.symlink?(path)
          next if File.directory?(path)
          files["#{PREFIX}/#{path.delete_prefix("#{SOURCE}/")}"] = {contents: File.binread(path), mode: 0o644}
        end
        files
      end

      def install
        raise ArgumentError, "system installation requires root; use --dry-run or --root for review" unless staged? || Process.euid.zero?
        raise ArgumentError, "use --root or --dry-run to prepare files for another platform" unless staged? || RUBY_PLATFORM.include?(@platform.to_s)
        validate_runtime! if @platform == :linux && !staged?
        validate_group! if @platform == :darwin || @policy == :sudoers
        plan.each do |absolute, item|
          destination = File.join(@root, absolute.delete_prefix("/"))
          secure_directory!(File.dirname(destination))
          safe_entry!(destination) if File.exist?(destination) || File.symlink?(destination)
          Tempfile.create([".vanken-", ".tmp"], File.dirname(destination)) do |file|
            file.binmode
            file.write(item[:contents])
            file.chmod(item[:mode])
            file.flush
            validate_sudoers!(file.path) if absolute == "/etc/sudoers.d/vanken" && !staged?
            File.rename(file.path, destination)
          end
        end
        self
      end

      def validate_runtime!
        trusted_tree!(@ruby)
        raise ArgumentError, "Ruby interpreter must be executable" unless File.file?(@ruby) && File.executable?(@ruby)
        runtime_prefix = File.dirname(File.dirname(File.realpath(@ruby)))
        trusted_tree!(runtime_prefix) unless ["/", "/usr"].include?(runtime_prefix)
        paths, status = Open3.capture2({"PATH" => "/usr/bin:/bin"}, @ruby, "--disable-gems", "-e", "$LOAD_PATH.each { |path| puts path }", unsetenv_others: true, chdir: "/")
        raise ArgumentError, "could not inspect the Ruby runtime" unless status.success?
        paths.each_line { |path| trusted_tree!(path.strip) }
        trusted_tree!(@gem_home)
        raise ArgumentError, "gem home must be a directory" unless File.directory?(@gem_home)
        trusted_tree!(SOURCE)
        self
      end

      def validate_group!
        Etc.getgrnam(@group)
      rescue ArgumentError
        raise ArgumentError, "create the #{@group} capture group and add the intended users before installing"
      end

      def next_steps
        if @platform == :darwin
          ["sudo launchctl bootstrap system /Library/LaunchDaemons/org.vanken.chmod-bpf.plist",
           "Log out and log in after changing group membership, then run vanken-capture --check --interface lo0."]
        else
          ["Run vanken-capture --check --interface IF as a normal user, then start Vanken."]
        end
      end

      private

      def asset(relative, mode: 0o644)
        contents = File.binread(File.join(SOURCE, "packaging", relative)).gsub("VANKEN_GROUP", @group)
        contents = contents.gsub("VANKEN_RUBY", Shellwords.escape(@ruby.to_s)).gsub("VANKEN_GEM_HOME", Shellwords.escape(@gem_home.to_s))
        {contents: contents, mode: mode}
      end

      def trusted_tree!(path, visited = {})
        resolved = trusted_path!(path)
        return if visited[resolved]
        visited[resolved] = true
        return unless File.directory?(resolved)
        Dir.children(resolved).each { |name| trusted_tree!(File.join(resolved, name), visited) }
      rescue SystemCallError => error
        raise ArgumentError, "cannot verify root-owned privileged path: #{error.message}"
      end

      def trusted_path!(path)
        resolved = File.realpath(path)
        current = path
        loop do
          stat = File.lstat(current)
          unless stat.uid.zero? && (stat.symlink? || (stat.mode & 0o022).zero?) && (stat.file? || stat.directory? || stat.symlink?)
            raise ArgumentError, "privileged paths must be root-owned without group or other write access"
          end
          if stat.symlink?
            target = File.readlink(current)
            trusted_path!(target.start_with?("/") ? target : File.join(File.dirname(current), target))
          end
          break if current == "/"
          current = File.dirname(current)
        end
        trusted_path!(resolved) if path != resolved
        resolved
      end

      def safe_entry!(path)
        stat = File.lstat(path)
        raise ArgumentError, "unsafe installation path or symlink: #{path}" unless stat.uid == Process.euid && (stat.mode & 0o022).zero? && (stat.file? || stat.directory?)
      end

      def secure_directory!(path)
        safe_entry!(@root)
        current = @root
        path.delete_prefix(@root).split("/").reject(&:empty?).each do |part|
          current = File.join(current, part)
          Dir.mkdir(current, 0o755) unless File.exist?(current) || File.symlink?(current)
          safe_entry!(current)
          raise ArgumentError, "installation parent is not a directory" unless File.directory?(current)
        end
      end

      def validate_sudoers!(path)
        executable = %w[/usr/sbin/visudo /sbin/visudo].find { |candidate| File.executable?(candidate) }
        raise ArgumentError, "visudo is required to install sudoers permissions" unless executable
        _, errors, status = Open3.capture3(executable, "-cf", path)
        raise ArgumentError, "invalid sudoers configuration: #{errors}" unless status.success?
      end
    end
  end
end
