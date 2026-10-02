# frozen_string_literal: true

module Vanken
  module App
    ExpertRow = Data.define(:severity, :code, :protocol, :message, :count, :numbers)

    module ExpertInfo
      def self.rows(document, displayed_only: false)
        displayed = document.display_numbers.to_set if displayed_only
        groups = {}
        document.annotations.experts.dup.each do |number, items|
          next if displayed && !displayed.include?(number)
          items.each do |item|
            key = [Gateway::Severity.normalize(item[:severity]), item[:code], item[:protocol]]
            group = (groups[key] ||= {message: item[:message], count: 0, numbers: []})
            group[:count] += 1
            group[:numbers] << number unless group[:numbers].last == number
          end
        end
        groups.map do |(severity, code, protocol), value|
          ExpertRow.new(severity: severity, code: code, protocol: protocol, **value.merge(numbers: value[:numbers].freeze))
        end.sort_by { |row| [-Gateway::Severity.rank(row.severity), row.protocol, row.code] }
      end
    end
  end
end
