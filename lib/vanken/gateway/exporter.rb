# frozen_string_literal: true
# rbs_inline: enabled

require "csv"
require "tempfile"
require_relative "file_writer"
require_relative "detail_builder"

module Vanken
  module Gateway
    class Exporter
      DEFAULT_COLUMNS = %i[number time source destination protocol length info].map { |key| {key: key, label: key.to_s.capitalize} }.freeze

      def initialize(document) = (@document = document)

      def numbers(scope: :all, range: "", selected: nil, exclude_ignored: false)
        limit = @document.count
        empty = [] #: Array[Integer]
        values = case scope.to_sym
        when :all then (1..limit).to_a
        when :displayed then @document.display_numbers
        when :selected then selected ? [selected] : empty
        when :marked then @document.marked.to_a
        when :between_marks
          marks = @document.marked.to_a.sort
          marks.empty? ? empty : (marks.first..marks.last).to_a
        when :range then ranges(range, limit)
        else raise ArgumentError, "invalid packet scope"
        end
        raise ArgumentError, "invalid packet number" unless values.all? { |number| number.is_a?(Integer) && number.between?(1, limit) }
        values = values.reject { |number| @document.ignored.include?(number) } if exclude_ignored
        values.sort.uniq
      end

      def write(path, format:, numbers: nil, columns: DEFAULT_COLUMNS, cancelled: nil)
        format = format.to_sym
        raise ArgumentError, "invalid export format" unless %i[pcap pcapng json ndjson text csv].include?(format)
        numbers = (numbers || self.numbers).to_a.sort.uniq
        raise IndexError, "invalid packet number" unless numbers.all? { |number| number.is_a?(Integer) && number.between?(1, @document.count) }
        file = Tempfile.create([".vanken-export-", ".tmp"], File.dirname(File.expand_path(path)))
        begin
          file.binmode
          case format
          when :pcap, :pcapng
            linktype = numbers.empty? ? 1 : @document.store.metadata(numbers.first)[:linktype]
            FileWriter.open(file, format: format, linktype: linktype) do |writer|
              numbers.each { |number| check_cancelled(cancelled); writer << @document.store.read(number) }
            end
          when :json, :ndjson then json(file, numbers, format, cancelled)
          when :text
            numbers.each do |number|
              check_cancelled(cancelled)
              @document.details(number).each { |node| text_node(file, node, 0) }
              file.write("\n")
            end
          when :csv
            csv = CSV.new(file)
            visible = columns.reject { |column| column[:visible] == false }
            csv << visible.map { |column| column[:label] || column[:key].to_s }
            numbers.each { |number| check_cancelled(cancelled); csv << visible.map { |column| csv_value(number, column) } }
          end
          file.flush
          file.fsync
          file.close
          File.rename(file.path, File.expand_path(path))
        ensure
          file.close unless file.closed?
          FileUtils.rm_f(file.path)
        end
        path
      end

      private

      def ranges(value, limit)
        raise ArgumentError, "packet range is empty" if value.strip.empty?
        value.split(",", -1).flat_map do |part|
          match = /\A\s*(\d+)(?:\s*-\s*(\d*))?\s*\z/.match(part)
          raise ArgumentError, "invalid packet range: #{part}" unless match
          first = match[1].to_i
          last = match[2].nil? ? first : match[2].empty? ? limit : match[2].to_i
          raise ArgumentError, "packet range is outside capture" unless first.between?(1, limit) && last.between?(first, limit)
          (first..last).to_a
        end
      end

      def check_cancelled(cancelled)
        raise Vanken::Error, "operation cancelled" if cancelled&.call || @document.closing?
      end

      def json(file, numbers, format, cancelled)
        dissector = Dissector.new(**@document.analysis_gateway_options)
        analysis = Analysis.new(registry: dissector.registry, **@document.analysis_options)
        selected = numbers.to_set
        written = false
        file.write("[") if format == :json
        # Replay preceding packets so stateful fields and reassembled layers match the document.
        (1..(numbers.last || 0)).each do |number|
          check_cancelled(cancelled)
          packet = dissector.dissect(@document.store.read(number))
          analysis.update(packet)
          next unless selected.include?(number)
          file.write(",") if format == :json && written
          file.write(JSON.generate(packet.to_h))
          file.write("\n") if format == :ndjson
          written = true
        end
        file.write("]\n") if format == :json
      ensure
        analysis&.close
      end

      def text_node(file, node, depth)
        file.write("#{'  ' * depth}#{node.label}\n")
        node.children.each { |child| text_node(file, child, depth + 1) }
      end

      def csv_value(number, column)
        return @document.view(number).values(column[:field]).map(&:to_s).join(", ") if column[:field]
        return @document.time_value(number, column[:format] || :relative) if column[:key].to_sym == :time
        @document.row(number)[column[:key].to_sym]
      end
    end
  end
end
