# frozen_string_literal: true

module Vanken
  module Core
    module DisplayFilter
      class SyntaxError < StandardError
        attr_reader :position, :length

        def initialize(message, position:, length: 1)
          super(message)
          @position = position
          @length = length
        end
      end
    end
  end
end
