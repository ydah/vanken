# frozen_string_literal: true

module Vanken
  module App
    module DocumentAnalysis
      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def recover(directory, **options)
          store = Core::FrameStore.recover(directory)
          new(store: store, **options).analyze_store
        rescue StandardError
          store&.close(remove: false)
          raise
        end
      end

      def analyze_store
        @source ||= :live
        @dirty = @source == :live unless @rebuilding
        @received, @analyzed, @cancelled = true, false, false
        @analyzer = @process_analysis ? Capture::AnalyzerProcess.new(self, verify_checksums: @verify_checksums) : Capture::Analyzer.new(self, @dissector)
        @jobs << thread { @analyzer.run }
        self
      end

      def reanalyze(decode_as: @analysis_gateway_options[:decode_as], plugins: @analysis_gateway_options[:plugins], preferences: nil)
        raise Vanken::Error, "stop capture or finish loading before changing analysis" if loading? || closing?
        options = @analysis_gateway_options.merge(decode_as: decode_as, plugins: plugins).freeze
        options = options.merge(verify_checksums: preferences.get("analysis.verify_checksums")).freeze if preferences
        dissector = Gateway::Dissector.new(**options)
        snapshot = @mutex.synchronize { reanalysis_snapshot }
        cancel_search if respond_to?(:cancel_search)
        cancel_scan
        wait(3)
        @mutex.synchronize do
          @analysis_gateway_options, @dissector = options, dissector
          @verify_checksums = options[:verify_checksums]
          if preferences
            @analysis_options = {max_state_bytes: preferences.get("analysis.max_state_mib") << 20, max_flows: preferences.get("analysis.max_flows")}.freeze
            @scan_concurrency = preferences.get("analysis.workers")
            @cache = Core::RowCache.new(limit: preferences.get("packet_list.row_cache_rows"))
          end
          @columns = Core::ColumnStore.new
          @annotations.close
          @annotations = Core::AnnotationStore.new(@store.directory)
          @cache.clear
          @catalog = Gateway::FieldCatalog.new(registry: @dissector.registry)
          @count, @display, @error = 0, (@filter ? [] : nil), nil
          @rebuilding = true
          @reanalysis_cancelled = false
          @rebuilding_filter_basis = @filter_basis
          @filter_context = @reanalysis_context = snapshot
          [@details, @detail_reader, @detail_index, @summaries, @summary_index, @summary_reader, @summary_index_reader].each(&:close)
          open_analysis_files
        end
        analyze_store
      end

      private

      def open_analysis_files
        @details = File.open(File.join(@store.directory, "details.jsonl"), "w+b", 0o600)
        @detail_reader = File.open(File.join(@store.directory, "details.jsonl"), "rb")
        @detail_index = File.open(File.join(@store.directory, "reassembled.idx"), "w+b", 0o600)
        @detail_offsets = {}
        @summaries = File.open(File.join(@store.directory, "summaries.bin"), "w+b", 0o600)
        @summary_index = File.open(File.join(@store.directory, "summaries.idx"), "w+b", 0o600)
        @summary_reader = File.open(File.join(@store.directory, "summaries.bin"), "rb")
        @summary_index_reader = File.open(File.join(@store.directory, "summaries.idx"), "rb")
        @summary_count = 0
      end
    end
  end
end
