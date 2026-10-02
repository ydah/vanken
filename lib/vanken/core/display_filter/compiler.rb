# frozen_string_literal: true

require_relative "parser"
require_relative "field_resolver"
require_relative "types"

module Vanken
  module Core
    module DisplayFilter
      class Program
        attr_reader :expression, :fields, :sources, :warnings

        def initialize(expression:, fields:, sources:, warnings:, evaluator:)
          @expression = expression.freeze
          @fields = fields.uniq.freeze
          @sources = sources.uniq.freeze
          @warnings = warnings.uniq.freeze
          @evaluator = evaluator
          freeze
        end

        def match?(view) = !!@evaluator.call(view)
        def fast? = !sources.include?(:dissect)
      end

      class Compiler
        def initialize(catalog: nil)
          @resolver = FieldResolver.new(catalog)
          @fields = []
          @sources = []
          @warnings = []
        end

        def compile(expression)
          @fields = []
          @sources = []
          @warnings = []
          parser = Parser.new(expression)
          ast = parser.parse
          evaluator = compile_node(ast)
          Program.new(expression: expression.dup, fields: @fields, sources: @sources,
                      warnings: parser.warnings + @warnings, evaluator: evaluator)
        end

        private

        def compile_node(node)
          case node.kind
          when :true then ->(_) { true }
          when :not
            child = compile_node(node.left)
            ->(view) { !child.call(view) }
          when :and, :or
            left = compile_node(node.left)
            right = compile_node(node.right)
            node.kind == :and ? ->(view) { left.call(view) && right.call(view) } :
                                ->(view) { left.call(view) || right.call(view) }
          when :test then compile_test(node)
          end
        end

        def compile_test(node)
          reference = @resolver.resolve(node.left.value)
          @fields << reference.name
          @sources << reference.source
          @warnings << "Unknown field: #{reference.name}" unless reference.known
          if reference.protocol
            Types.fail_at("Protocols only support presence tests", node.right.token) if node.right
            return ->(view) { view.layer?(reference.name) }
          end
          return ->(view) { !Array(view.values(reference.name)).compact.empty? } unless node.right

          operator = node.right.operator
          predicate = %i[ne any_ne].include?(operator) ?
            Predicate.new(:eq, node.right.members, node.right.token) : node.right
          comparison = Types.predicate(predicate, reference.type)
          lambda do |view|
            values = Array(view.values(reference.name)).compact
            type = @resolver.normalize_type(view.field_type(reference.name)) if !reference.type && view.respond_to?(:field_type)
            if operator == :ne
              values.none? { |value| comparison.call(value, type) }
            elsif operator == :any_ne
              values.any? { |value| !comparison.call(value, type) }
            else
              values.any? { |value| comparison.call(value, type) }
            end
          end
        end
      end

      def self.compile(expression, catalog: nil)
        Compiler.new(catalog: catalog).compile(expression)
      end
    end
  end
end
