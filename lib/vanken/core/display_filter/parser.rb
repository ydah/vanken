# frozen_string_literal: true

require_relative "lexer"

module Vanken
  module Core
    module DisplayFilter
      Node = Data.define(
        :kind, #: Symbol
        :left, #: untyped
        :right #: untyped
      )
      Predicate = Data.define(
        :operator, #: Symbol
        :values, #: Array[Member]
        :token #: Token
      )
      Member = Data.define(
        :first, #: Token
        :last #: Token?
      )

      class Parser
        PRECEDENCE = {or: 10, and: 20}.freeze
        VALUES = %i[integer float string address mac bytes boolean identifier].freeze
        RELATIONS = %i[eq ne any_ne gt lt ge le contains].freeze
        attr_reader :warnings #: Array[String]

        # @rbs (String expression) -> void
        def initialize(expression)
          @tokens = Lexer.new(expression).tokens
          raise SyntaxError.new("Filter has too many tokens", position: @tokens[512].position) if @tokens.size > 512
          @index = 0
          @warnings = []
          @scopes = [[]] #: Array[Array[Symbol]]
          @scope = 0
          @depth = 0
        end

        # @rbs () -> Node
        def parse
          return Node.new(:true, nil, nil) if current.type == :eof

          ast = expression(0)
          expect_token(:eof)
          if @scopes.any? { |operators| operators.uniq.size > 1 }
            @warnings << "Use parentheses when mixing and with or"
          end
          ast
        end

        private

        # @rbs (Integer minimum) -> Node
        def expression(minimum)
          left = primary
          while current.type == :operator && (precedence = PRECEDENCE[current.value]) && precedence >= minimum
            operator = advance.value
            @scopes[@scope] << operator
            left = Node.new(operator, left, expression(precedence + 1))
          end
          left
        end

        # @rbs () -> Node
        def primary
          @depth += 1
          fail_at("Filter nesting exceeds 64 levels", current) if @depth > 64
          if current.type == :operator && current.value == :not
            advance
            return Node.new(:not, primary, nil)
          end
          if current.type == :lparen
            advance
            parent_scope = @scope
            @scope = @scopes.length
            scope = [] #: Array[Symbol]
            @scopes << scope
            node = expression(0)
            expect_token(:rparen)
            @scope = parent_scope
            return node
          end
          field = expect_token(:identifier)
          Node.new(:test, field, predicate)
        ensure
          @depth -= 1
        end

        # @rbs () -> Predicate?
        def predicate
          return nil unless current.type == :operator
          return nil if PRECEDENCE.key?(current.value)

          operator = advance
          if RELATIONS.include?(operator.value)
            members = [Member.new(value, nil)]
          elsif operator.value == :matches
            members = [Member.new(expect_token(:string), nil)]
          elsif operator.value == :bitmask
            members = [Member.new(expect_token(:integer), nil)]
          elsif operator.value == :in
            members = set_members
          else
            fail_at("Unexpected operator", operator)
          end
          Predicate.new(operator.value, members, operator)
        end

        # @rbs () -> Array[Member]
        def set_members
          expect_token(:lbrace)
          members = [] #: Array[Member]
          loop do
            first = value
            last = current.type == :range ? (advance; value) : nil
            members << Member.new(first, last)
            break if current.type == :rbrace

            advance if current.type == :comma
          end
          expect_token(:rbrace)
          members
        end

        # @rbs () -> Token
        def value
          return advance if VALUES.include?(current.type)

          fail_at("Expected a value", current)
        end

        # @rbs (Symbol type) -> Token
        def expect_token(type)
          return advance if current.type == type

          fail_at("Expected #{type}", current)
        end

        # @rbs () -> Token
        def current = @tokens.fetch(@index)

        # @rbs () -> Token
        def advance
          token = current
          @index += 1
          token
        end

        # @rbs (String message, Token token) -> bot
        def fail_at(message, token)
          raise SyntaxError.new(message, position: token.position, length: token.length)
        end
      end
    end
  end
end
