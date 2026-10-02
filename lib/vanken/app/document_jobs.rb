# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module App
    module DocumentJobs
      def apply_filter(expression)
        program = Core::DisplayFilter.compile(expression, catalog: @catalog)
        cancel_scan
        if expression.empty?
          @mutex.synchronize do
            @filter = @filter_context = @filter_basis = @display = @progress = @filter_job = nil
            @filter_live_predecessors = @filter_live_predecessor_start = nil
          end
          notify(force: true)
          return self
        end
        generation, limit, snapshot = @mutex.synchronize do
          context = filter_snapshot(displayed_delta: program.fields.include?("frame.time_delta_displayed"))
          @filter = program
          @filter_context = context
          @filter_basis = context
          @filter_live_predecessors = program.fields.include?("frame.time_delta_displayed") ? "".b : nil
          @filter_live_predecessor_start = @filter_live_predecessors ? @count + 1 : nil
          # Reserve the history's capacity before publishing matches without placeholder rows.
          @display = Array.new(@count)
          @display[0, @count] = []
          @progress = 0.0
          [@generation, @count, context]
        end
        @filter_job = thread do
          if @scanner && !program.fast?
            path = @mutex.synchronize { @annotations.snapshot(File.join(@store.directory, "annotations-#{generation}.json")) }
            snapshot = snapshot.merge(annotations_json: path).freeze
          end
          historical_cursor = 0
          ranges = (1..limit).step(10_000).map { |first| [first, [first + 10_000, limit + 1].min] }
          ranges.each_slice(@scanner && !program.fast? ? @scan_concurrency : 1) do |window|
            break if stale_job?(generation)
            pending = window.map do |first, last|
              if @scanner && !program.fast?
                task = @scanner.call(filter_payload(first, last, expression: expression, snapshot: snapshot))
                stale = @mutex.synchronize do
                  @filter_tasks << task if generation == @generation && task.respond_to?(:cancel)
                  generation != @generation
                end
                task.cancel if stale && task.respond_to?(:cancel)
                [last, task]
              else
                [last, {"matches" => (first...last).select { |number| !stale_job?(generation) && program.match?(view(number, snapshot: snapshot)) }}]
              end
            end
            pending.each do |last, task|
              break if stale_job?(generation)
              value = task.respond_to?(:await) ? task.await : task
              break if stale_job?(generation)
              matches = value.fetch("matches")
              @mutex.synchronize do
                next if generation != @generation
                @display[historical_cursor, 0] = matches
                historical_cursor += matches.length
                @progress = (last - 1).fdiv([limit, 1].max)
              end
              notify
            end
          end
          @mutex.synchronize do
            next if generation != @generation
            @filter_context = nil
            @progress = nil
            @filter_tasks.clear
          end
          notify(force: true) unless stale_job?(generation)
        rescue StandardError => error
          fail(error) unless stale_job?(generation)
        ensure
          tasks = @mutex.synchronize do
            if generation == @generation
              @progress = nil
              @filter_context = nil
              remaining, @filter_tasks = @filter_tasks, []
              remaining
            else
              []
            end
          end
          tasks.each(&:cancel)
          File.unlink(path) if path && File.exist?(path)
        end
        @jobs << @filter_job
        self
      end

      def cancel_scan
        cancel_search
        tasks = @mutex.synchronize do
          @generation += 1
          @progress = nil
          @filter_context = nil
          saved, @filter_tasks = @filter_tasks, []
          saved
        end
        tasks.each(&:cancel)
        self
      end

      def filter_payload(first, last, expression: @filter&.expression || "", snapshot: nil)
        unless snapshot
          displayed_delta = Core::DisplayFilter.compile(expression, catalog: @catalog).fields.include?("frame.time_delta_displayed")
          snapshot = @mutex.synchronize do
            @snapshot_sequence = (@snapshot_sequence || 0) + 1
            filter_snapshot(displayed_delta: displayed_delta).merge(annotations_json: @annotations.snapshot(File.join(@store.directory, "annotations-#{@generation}-#{@snapshot_sequence}.json")))
          end
        end
        predecessors = (first...last).to_h { |number| [number.to_s, displayed_predecessor(number, snapshot)] }
        {"spool" => @store.directory, "expr" => expression, "from" => first, "to" => last,
         "decode_as" => @analysis_gateway_options[:decode_as], "plugins" => @analysis_gateway_options[:plugins], "annotations_json" => snapshot[:annotations_json],
         "marked" => snapshot[:marked].select { |number| number >= first && number < last },
         "ignored" => snapshot[:ignored].select { |number| number >= first && number < last },
         "time_references_ns" => snapshot[:references].to_h { |number| [number.to_s, @store.metadata(number)[:timestamp_ns]] },
         "time_reference_ns" => snapshot[:limit].zero? ? 0 : @store.metadata(1)[:timestamp_ns],
         "displayed_predecessors" => predecessors}
      end

      def displayed_predecessor(number, snapshot)
        if (packed = snapshot[:live_predecessors]) && number >= snapshot[:live_predecessor_start]
          offset = (number - snapshot[:live_predecessor_start]) * 8
          return packed.unpack1("Q<", offset: offset) if offset < packed.bytesize
        end
        return number - 1 unless snapshot[:predecessors]
        return snapshot[:last_displayed] || 0 if number > snapshot[:limit]
        snapshot[:predecessors].fetch(number, 0)
      end

      def sort(key, direction = :asc)
        cancel_search
        raise ArgumentError, "invalid sort direction" unless %i[asc desc].include?(direction)
        custom_field = custom_columns.find { |item| item["key"] == key.to_s }&.fetch("field")
        generation, sort_generation, filter_job = @mutex.synchronize do
          @sort_generation = (@sort_generation || 0) + 1
          [@generation, @sort_generation, @filter_job]
        end
        @jobs << thread do
          filter_job&.join
          next if generation != @generation || sort_generation != @sort_generation || @closing
          numbers = display_numbers
          values = numbers.to_h do |number|
            value = if custom_field
              custom_sort_value(number, custom_field)
            else
              case key.to_sym
              when :no, :number then number
              when :time then @store.metadata(number)[:timestamp_ns]
              when :length then @store.metadata(number)[:original_length]
              else row(number).fetch(key.to_sym)
              end
            end
            [number, value]
          end
          numbers.sort! { |a, b| comparison = values[a] <=> values[b]; comparison = -comparison if direction == :desc; comparison.zero? ? a <=> b : comparison }
          @mutex.synchronize do
            next if generation != @generation || sort_generation != @sort_generation || @closing
            @display = numbers + (@display ? @display - numbers : ((1..@count).to_a - numbers))
          end
          notify(force: true)
        end
        self
      end

      def save(path, format: nil, numbers: nil)
        @error = nil
        format ||= File.extname(path) == ".pcap" ? :pcap : :pcapng
        limit = @store.durable_count
        @save_job = thread do
          temporary = Tempfile.create([".vanken-", ".tmp"], File.dirname(File.expand_path(path)))
          begin
            linktype = limit.zero? ? 1 : @store.metadata(1)[:linktype]
            Gateway::FileWriter.open(temporary, format: format, linktype: linktype) do |writer|
              (numbers || (1..limit)).each { |number| writer << @store.read(number) }
            end
            temporary.flush
            temporary.fsync
            temporary.close
            File.rename(temporary.path, File.expand_path(path))
            @mutex.synchronize do
              @saved_count = limit unless numbers
              @dirty = false if !numbers && @store.count == limit
              @path = File.expand_path(path) unless numbers
            end
            notify(force: true)
          ensure
            temporary.close unless temporary.closed?
            FileUtils.rm_f(temporary.path)
          end
        end
        @jobs << @save_job
        self
      end

      def wait_for_save(timeout = nil)
        raise Vanken::Error, "save operation did not stop" if @save_job && !@save_job.join(timeout)
        self
      end

      private
      def stale_job?(generation) = @closing || generation != @generation
      # Retain only post-filter arrivals, at eight bytes per packet, and only for
      # displayed-delta filters. Rebuilds read this basis without replacing it.
      def record_live_predecessors(first, last, matches, context: @filter_context)
        return unless @filter_live_predecessors
        return if @rebuilding && @filter_basis.equal?(@rebuilding_filter_basis)
        previous = (@display ? @display.last : @count) || 0
        cursor = 0
        (first..last).each do |number|
          if number >= @filter_live_predecessor_start
            raise Vanken::Error, "nonsequential displayed-delta history" unless number == @filter_live_predecessor_start + (@filter_live_predecessors.bytesize / 8)
            predecessor = context ? displayed_predecessor(number, context) : previous
            @filter_live_predecessors << [predecessor].pack("Q<")
          end
          if matches[cursor] == number
            previous = number
            cursor += 1
          end
        end
      end

      def reanalysis_snapshot
        basis = @filter_basis || filter_snapshot(displayed_delta: !!@filter&.fields&.include?("frame.time_delta_displayed"))
        return basis unless @filter_live_predecessors
        basis.merge(live_predecessors: @filter_live_predecessors.dup.freeze,
          live_predecessor_start: @filter_live_predecessor_start, limit: @count).freeze
      end

      def filter_snapshot(displayed_delta: true)
        predecessors = @display.each_with_index.to_h { |number, index| [number, index.zero? ? 0 : @display[index - 1]] }.freeze if displayed_delta && @display
        {marked: @marked.dup.freeze, ignored: @ignored.dup.freeze, references: @time_references.dup.freeze,
         predecessors: predecessors,
         limit: @count, last_displayed: @display ? @display.last : @count}.freeze
      end
    end
  end
end
