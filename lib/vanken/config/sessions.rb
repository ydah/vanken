# frozen_string_literal: true

require "tmpdir"
require "json"

module Vanken
  module Config
    module Sessions
      def self.candidates(parent: Dir.tmpdir)
        Dir.glob(File.join(parent, "vanken-*" )).select { |directory| orphan?(directory) }.sort
      end

      def self.recover(directory, parent: Dir.tmpdir, **options)
        with_session(directory, parent: parent) { App::Document.recover(directory, **options) }
      end

      def self.discard(directory, parent: Dir.tmpdir)
        store = with_session(directory, parent: parent) { Core::FrameStore.recover(directory) }
        store.close
      end

      def self.orphan?(directory)
        return false unless File.directory?(directory) && !File.symlink?(directory)
        stat = File.stat(directory)
        return false unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
        Dir.children(directory).each do |name|
          stat = File.lstat(File.join(directory, name))
          return false unless stat.file? && stat.uid == Process.uid && stat.nlink == 1
        end
        path = File.join(directory, "session.json")
        return false unless File.file?(path) && File.size(path) <= 65_536
        return false unless %w[frames.bin frames.idx].all? { |name| File.file?(File.join(directory, name)) }
        session = JSON.parse(File.read(path))
        pid = session["pid"]
        return false unless session["schema_version"] == 1 && pid.is_a?(Integer) && pid.positive?
        begin
          Process.kill(0, pid)
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end
      rescue SystemCallError, JSON::ParserError, TypeError, NoMethodError
        false
      end

      def self.with_session(directory, parent:)
        path = File.expand_path(directory)
        raise Vanken::FileError, "session is active or unsafe" unless candidates(parent: parent).include?(path)
        File.open(File.join(path, "session.json"), "r+b") do |file|
          raise Vanken::FileError, "session is being recovered" unless file.flock(File::LOCK_EX | File::LOCK_NB)
          raise Vanken::FileError, "session is active or unsafe" unless orphan?(path)
          original = file.read
          begin
            yield
          rescue StandardError
            file.rewind
            file.truncate(0)
            file.write(original)
            file.flush
            raise
          end
        end
      end
      private_class_method :orphan?, :with_session
    end
  end
end
