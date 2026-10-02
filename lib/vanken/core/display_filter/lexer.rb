# frozen_string_literal: true

require "strscan"
require "ipaddr"
require_relative "errors"

module Vanken
  module Core
    module DisplayFilter
      Token = Data.define(:type, :value, :position, :length, :raw)

      class Lexer
        OPERATORS = {
          "==" => :eq, "eq" => :eq, "!=" => :ne, "ne" => :ne, "~=" => :any_ne, "any_ne" => :any_ne,
          ">" => :gt, "gt" => :gt, "<" => :lt, "lt" => :lt, ">=" => :ge, "ge" => :ge,
          "<=" => :le, "le" => :le, "contains" => :contains, "matches" => :matches, "in" => :in,
          "&" => :bitmask, "and" => :and, "&&" => :and, "or" => :or, "||" => :or,
          "not" => :not, "!" => :not
        }.freeze
        PUNCTUATION = {"(" => :lparen, ")" => :rparen, "{" => :lbrace, "}" => :rbrace,
                       "," => :comma, ".." => :range}.freeze

        def initialize(expression)
          @scanner = StringScanner.new(expression)
        end

        def tokens
          result = []
          until @scanner.eos?
            next if @scanner.scan(/\s+/)

            position = @scanner.pos
            if @scanner.peek(1) == '"'
              value = read_string(position)
              raw = @scanner.string.byteslice(position...@scanner.pos)
              result << Token.new(:string, value, position, raw.bytesize, raw)
              next
            end
            raw = @scanner.scan(/==|!=|~=|>=|<=|&&|\|\||\.\.|[(){}<>&!,]/) ||
                  @scanner.scan(/(?:(?!\.\.)[^\s(){}<>=!~&|,"'])+/)
            fail_at("Unexpected character", position, 1) unless raw
            type, value = classify(raw, position)
            result << Token.new(type, value, position, raw.bytesize, raw)
          end
          result << Token.new(:eof, nil, @scanner.pos, 0, "")
        end

        private

        def read_string(position)
          @scanner.getch
          value = +"".b
          until @scanner.eos?
            character = @scanner.getch
            if character == '"'
              value.force_encoding(@scanner.string.encoding)
              return value.valid_encoding? ? value : value.b
            end
            if character == "\\"
              escaped = @scanner.getch
              if escaped == "x"
                hex = @scanner.scan(/[0-9a-fA-F]{2}/)
                fail_at("Expected two hexadecimal escape digits", position, @scanner.pos - position) unless hex
                value << hex.to_i(16).chr
              elsif escaped == '"' || escaped == "\\"
                value << escaped
              else
                fail_at("Unknown string escape", position, @scanner.pos - position)
              end
            else
              value << character.b
            end
          end
          fail_at("Unterminated string", position, @scanner.pos - position)
        end

        def classify(raw, position)
          return [:operator, OPERATORS.fetch(raw)] if OPERATORS.key?(raw)
          return [PUNCTUATION.fetch(raw), raw] if PUNCTUATION.key?(raw)
          return [:boolean, raw == "true"] if %w[true false].include?(raw)
          if /\A-?(?:0x[\da-f]+|0o[0-7]+|0b[01]+|\d+)\z/i.match?(raw)
            return [:integer, Integer(raw, raw.match?(/\A-?0[xob]/i) ? 0 : 10)]
          end
          if /\A-?(?:\d+\.\d+(?:e[+-]?\d+)?|\d+e[+-]?\d+)\z/i.match?(raw)
            value = Float(raw)
            fail_at("Number must be finite", position, raw.bytesize) unless value.finite?
            return [:float, value]
          end
          return [:mac, raw] if /\A(?:[\da-f]{2}:){5}[\da-f]{2}\z/i.match?(raw) ||
                               /\A(?:[\da-f]{2}-){5}[\da-f]{2}\z/i.match?(raw) ||
                               /\A[\da-f]{4}\.[\da-f]{4}\.[\da-f]{4}\z/i.match?(raw)
          return [:bytes, raw] if /\A(?:[\da-f]{2}:)+[\da-f]{2}\z/i.match?(raw) && raw.count(":") != 7
          if raw.include?(":") || /\A\d+\./.match?(raw)
            begin
              IPAddr.new(raw)
              return [:address, raw]
            rescue IPAddr::Error
              fail_at("Invalid address", position, raw.bytesize)
            end
          end
          return [:identifier, raw] if /\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\z/.match?(raw)

          fail_at("Invalid token #{raw.inspect}", position, raw.bytesize)
        end

        def fail_at(message, position, length)
          raise SyntaxError.new(message, position: position, length: length)
        end
      end
    end
  end
end
