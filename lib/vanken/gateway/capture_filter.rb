# frozen_string_literal: true

require "redhound"

module Vanken
  module Gateway
    module CaptureFilter
      class Error < StandardError
        attr_reader :position

        def initialize(message, position: nil)
          @position = position
          super(message)
        end
      end

      def self.compile(expression, linktype: 1, snaplen: 262_144, live: false)
        raise Error, "capture filter exceeds 8192 bytes" unless expression.is_a?(String) && expression.bytesize <= 8192

        program = Redhound::Filter.compile(expression, linktype: linktype, snaplen: snaplen, live: live)
        Redhound::Filter::BPF::Validator.validate!(program.instructions)
        program
      rescue Redhound::FilterError => e
        raise Error.new(e.message, position: e.respond_to?(:position) ? e.position : nil)
      end
    end
  end
end
