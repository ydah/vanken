# frozen_string_literal: true

module Vanken
  module Capture
    module Privileges
      class Error < StandardError; end

      def self.drop!(uid, gid)
        raise Error, "refusing a root identity" unless uid.is_a?(Integer) && gid.is_a?(Integer) && uid.positive? && gid.positive?

        Process.groups = []
        Process::GID.change_privilege(gid)
        Process::UID.change_privilege(uid)
        unless Process.uid == uid && Process.euid == uid && Process.gid == gid && Process.egid == gid && Process.groups.empty?
          raise Error, "could not verify dropped privileges"
        end

        true
      rescue SystemCallError => e
        raise Error, "could not drop privileges: #{e.message}"
      end
    end
  end
end
