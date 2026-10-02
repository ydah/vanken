# frozen_string_literal: true

require "ipaddr"

module Vanken
  module Core
    module DisplayFilter
      module Types
        NUMERIC = %i[integer float].freeze
        ORDERED = %i[integer float severity].freeze
        SEVERITIES = {"note" => 0, "warning" => 1, "warn" => 1, "error" => 2}.freeze
        module_function

        # @rbs (Predicate predicate, field_type? type) -> ^(untyped, field_type?) -> bool
        def predicate(predicate, type)
          operator = predicate.operator
          validate_operator(operator, type, predicate.token)
          regex = regular_expression(predicate.values.first.first) if operator == :matches
          members = prepare_members(predicate.values, type) if type
          lambda do |actual, runtime_type|
            value_type = type || runtime_type || infer_type(actual, predicate.values.first.first)
            validate_operator(operator, value_type, predicate.token) unless type
            prepared = members || prepare_members(predicate.values, value_type)
            value = actual_value(actual, value_type)
            compare(value, operator, prepared, regex, value_type)
          rescue ArgumentError, TypeError, Regexp::TimeoutError, SyntaxError
            false
          end
        end

        # @rbs (Symbol operator, field_type? type, Token token) -> void
        def validate_operator(operator, type, token)
          return unless type

          allowed = case operator
          when :bitmask then type == :integer
          when :contains then %i[string bytes].include?(type)
          when :matches then type == :string
          when :gt, :lt, :ge, :le then ORDERED.include?(type)
          else true
          end
          fail_at("#{operator} is not supported for #{type}", token) unless allowed
        end

        # @rbs (Array[Member] members, field_type? type) -> Array[prepared_member]
        def prepare_members(members, type)
          members.map do |member|
            first = literal(member.first, type)
            last = literal(member.last, type) if member.last
            if member.last && (!ORDERED.include?(type) || first > last)
              fail_at("Invalid range", member.last)
            end
            [first, last]
          end
        end

        # @rbs (Token token, field_type? type) -> untyped
        def literal(token, type)
          case type
          when :integer, :float
            fail_at("Expected a numeric value", token) unless NUMERIC.include?(token.type)
            token.value
          when :boolean
            return token.value if token.type == :boolean
            return token.value == 1 if token.type == :integer && [0, 1].include?(token.value)

            fail_at("Expected true, false, 1, or 0", token)
          when :address
            IPAddr.new(token.value.to_s)
          when :mac
            normalized_mac(token.value)
          when :bytes
            return [token.raw.delete_prefix("0x").delete_prefix("0X")].pack("H*") if token.type == :integer && token.raw.match?(/\A0x(?:[\da-f]{2})+\z/i)
            return [token.value.delete(".:-")].pack("H*") if %i[bytes mac].include?(token.type) ||
              (token.type == :address && /\A(?:[\da-f]{2}:)+[\da-f]{2}\z/i.match?(token.raw))
            return token.value.b if token.type == :string

            fail_at("Expected bytes or a string", token)
          when :severity
            SEVERITIES.fetch(token.value.to_s) { fail_at("Expected note, warning, or error", token) }
          when :string
            fail_at("Expected a string", token) unless %i[string identifier].include?(token.type)
            token.value
          else
            token.type == :address ? IPAddr.new(token.value) : token.value
          end
        rescue ArgumentError
          fail_at("Invalid #{type} value", token)
        end

        # @rbs (untyped value, field_type? type) -> untyped
        def actual_value(value, type)
          case type
          when :address then value.is_a?(IPAddr) ? value : IPAddr.new(value.to_s)
          when :mac then normalized_mac(value)
          when :bytes then value.b
          when :severity then SEVERITIES.fetch(value.to_s)
          when :string then value.to_s
          when :boolean
            return value if value == true || value == false
            return value == 1 if value == 0 || value == 1

            raise TypeError, "Invalid boolean value"
          when :integer, :float
            raise TypeError, "Invalid numeric value" unless value.is_a?(Numeric)
            value
          else value
          end
        end

        # @rbs (untyped actual, Token token) -> field_type
        def infer_type(actual, token)
          return :boolean if actual == true || actual == false
          return :integer if actual.is_a?(Integer)
          return :float if actual.is_a?(Numeric)
          return :address if actual.is_a?(IPAddr) || token.type == :address
          return :mac if token.type == :mac
          return :bytes if token.type == :bytes || (actual.is_a?(String) && actual.encoding == Encoding::BINARY)

          :string
        end

        # @rbs (untyped value, Symbol operator, Array[prepared_member] members, Regexp? regex, field_type? type) -> bool
        def compare(value, operator, members, regex, type)
          expected = members.first.first
          case operator
          when :eq, :ne, :any_ne
            equal = type == :address ? expected.include?(value) : value == expected
            operator == :eq ? equal : !equal
          when :gt then value > expected
          when :lt then value < expected
          when :ge then value >= expected
          when :le then value <= expected
          when :contains then value.include?(expected)
          when :matches then !!regex&.match?(value)
          when :bitmask then (value & expected) != 0
          when :in
            members.any? do |first, last|
              if last
                value >= first && value <= last
              elsif type == :address
                first.include?(value)
              else
                value == first
              end
            end
          else raise ArgumentError, "Unknown filter operator: #{operator}"
          end
        end

        # @rbs (untyped value) -> String
        def normalized_mac(value)
          string = value.to_s
          valid = /\A(?:[\da-f]{2}:){5}[\da-f]{2}\z/i.match?(string) ||
                  /\A(?:[\da-f]{2}-){5}[\da-f]{2}\z/i.match?(string) ||
                  /\A[\da-f]{4}\.[\da-f]{4}\.[\da-f]{4}\z/i.match?(string)
          raise ArgumentError, "Invalid MAC address" unless valid

          string.delete(".:-").downcase
        end

        # @rbs (Token token) -> Regexp
        def regular_expression(token)
          Regexp.new(token.value, timeout: 0.1)
        rescue RegexpError
          fail_at("Invalid regular expression", token)
        end

        # @rbs (String message, Token token) -> bot
        def fail_at(message, token)
          raise SyntaxError.new(message, position: token.position, length: token.length)
        end
      end
    end
  end
end
