# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Core
    Frame = Data.define(
      :bytes, #: String
      :timestamp_ns, #: Integer
      :original_length, #: Integer
      :linktype, #: Integer
      :interface, #: Hash[String, untyped]?
      :direction, #: (:in | :out)?
      :number #: Integer
    )
    DetailNode = Data.define(
      :id, #: String
      :label, #: String
      :field, #: String?
      :offset, #: Integer?
      :length, #: Integer
      :source, #: Symbol
      :severity, #: Symbol?
      :filter, #: String?
      :children #: Array[DetailNode]
    )
    class DetailNode
      # @rbs () -> Array[DetailNode]
      def descendants = [self, *children.flat_map(&:descendants)]
      # @rbs () -> Hash[Symbol, untyped]
      def to_h = super.merge(children: children.map(&:to_h))
    end
  end
end
