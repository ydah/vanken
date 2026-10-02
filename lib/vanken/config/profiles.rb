# frozen_string_literal: true

require_relative "preferences"
require_relative "yaml_file"

module Vanken
  module Config
    class Profiles
      FILES = %w[preferences.yml coloring_rules.yml columns.yml filters.yml decode_as.yml plugins.yml].freeze
      attr_reader :directory, :active

      def initialize(directory: Paths.config)
        @directory = File.expand_path(directory)
        @active = YamlFile.read(File.join(@directory, "profiles.yml"), default: {"active" => "default"}).fetch("active", "default")
        profile_directory(@active)
        @active = "default" unless names.include?(@active)
      end

      def names
        ["default", *Dir.glob(File.join(@directory, "profiles", "*")).select { |path| File.directory?(path) && !File.symlink?(path) }.map { |path| File.basename(path) }.sort]
      end

      def preferences
        shared = @directory == File.expand_path(Paths.config) ? Paths.state : File.join(@directory, "state")
        Preferences.new(directory: profile_directory(@active), state_directory: shared)
      end

      def create(name, copy_from: nil)
        target = profile_directory(name)
        raise ConfigError, "profile already exists" if names.include?(name) || File.exist?(target) || File.symlink?(target)
        raise ConfigError, "unknown profile" if copy_from && !names.include?(copy_from)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        Dir.mkdir(target, 0o700)
        if copy_from
          source = profile_directory(copy_from)
          FILES.each do |file|
            path = File.join(source, file)
            next unless File.file?(path)
            raise ConfigError, "profile file must not be a symlink" if File.symlink?(path)
            File.write(File.join(target, file), File.binread(path), mode: "wb", perm: 0o600)
          end
        else
          Preferences.new(directory: target).save
        end
        name
      end

      def switch(name)
        profile_directory(name)
        raise ConfigError, "unknown profile" unless names.include?(name)
        @active = name
        YamlFile.write(File.join(@directory, "profiles.yml"), "active" => name)
        preferences
      end

      def delete(name)
        path = profile_directory(name)
        raise ConfigError, "cannot delete the active or default profile" if name == @active || name == "default"
        raise ConfigError, "unknown profile" unless names.include?(name)
        FileUtils.remove_entry_secure(path)
      end

      private

      def profile_directory(name)
        raise ConfigError, "invalid profile name" unless name.is_a?(String) && name.match?(/\A[\p{L}\p{N}_ -][\p{L}\p{N}_. -]{0,63}\z/) && !%w[. ..].include?(name)
        path = name == "default" ? @directory : File.join(@directory, "profiles", name)
        raise ConfigError, "profiles directory must not be a symlink" if name != "default" && File.symlink?(File.join(@directory, "profiles"))
        raise ConfigError, "profile must not be a symlink" if File.symlink?(path)
        path
      end
    end
  end
end
