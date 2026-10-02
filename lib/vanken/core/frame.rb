# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Core
    Frame = Data.define(:bytes, :timestamp_ns, :original_length, :linktype, :interface, :direction, :number)
    DetailNode = Data.define(:id, :label, :field, :offset, :length, :source, :severity, :filter, :children) do
      def descendants = [self, *children.flat_map(&:descendants)]
      def to_h = super.merge(children: children.map(&:to_h))
    end
  end
end
