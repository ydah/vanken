# frozen_string_literal: true

require "digest"
require_relative "../app/stats_job"
require_relative "../app/expert_info"
require_relative "../app/io_graph"
require_relative "../gateway/stream"
require_relative "../gateway/exporter"

module Vanken
  module UI
    class AnalysisRows
      def initialize(rows) = (@rows = rows)
      def count = @rows.size
      def row_id(index) = index
      def cell(index, key)
        value = @rows.fetch(index).to_h[key]
        value.is_a?(Array) ? value.join(" / ") : value
      end
      def sort(key, direction)
        @rows.sort_by! { |row| row.to_h[key] || "" }
        @rows.reverse! if direction == :desc
      end
      def [](index) = @rows.fetch(index)
    end

    module AnalysisDialogs
      ANALYSIS_KINDS = %i[protocol_hierarchy conversations endpoints expert_info io_graph follow_tcp_stream file_properties].freeze

      def close_analysis
        @analysis_generation = (@analysis_generation || 0) + 1
        @statistics_job&.cancel
        @statistics_job = nil
        # Await actual completion; Task#cancel alone does not join an executing worker.
        @analysis_task&.await
      rescue StandardError
        nil
      ensure
        @analysis_task = @analysis_results = @analysis_refresh = nil
        @follow_stream = @follow_text = nil
        @analysis_running = false
      end

      def refresh_analysis
        return unless @analysis_refresh && ANALYSIS_KINDS.include?(@dialog_kind) && !@analysis_running && !@closing
        @analysis_refresh.call
      end

      def protocol_hierarchy = statistics_dialog(:protocol_hierarchy)
      def conversations = statistics_dialog(:conversations)
      def endpoints = statistics_dialog(:endpoints)

      def statistics_dialog(kind, displayed_only: false)
        return unless document
        types = %w[eth ip ipv6 tcp udp]
        specs = kind == :protocol_hierarchy ? ["phs"] : types.map { |type| "#{kind == :conversations ? 'conv' : 'endpoints'},#{type}" }
        controls = Zaniah::UI::Checkbox.new(t("表示中のパケットのみ"), value: displayed_only).test_id("vk.stats.displayed")
          .on_change { |value, *_| statistics_dialog(kind, displayed_only: value) }
        analysis_dialog(kind, {protocol_hierarchy: t("プロトコル階層"), conversations: t("会話"), endpoints: t("端点")}.fetch(kind), controls, reopen: -> { statistics_dialog(kind, displayed_only: displayed_only) })
        @statistics_job = App::StatsJob.new(document, specs: specs, displayed_only: displayed_only)
        job = @statistics_job
        @analysis_refresh = lambda do
          analysis_background(->(*) { job.refresh }) do |tables|
            if kind == :protocol_hierarchy
              rows = tables.first.rows
              total = rows.select { |row| row.path.size == 1 }.sum(&:packets)
              nodes = rows.to_h do |row|
                id = row.path.join("/")
                label = t("%{protocol}   %{packets} パケット   %{bytes} bytes   %{percent}%", protocol: row.path.last, packets: row.packets, bytes: row.bytes, percent: total.zero? ? 0 : (row.packets * 100.0 / total).round(1))
                [id, Core::DetailNode.new(id: id, label: label, field: nil, offset: nil, length: 0, source: :frame, severity: nil, filter: nil, children: [])]
              end
              roots = []
              rows.each do |row|
                node = nodes.fetch(row.path.join("/"))
                parent = nodes[row.path.take(row.path.size - 1).join("/")]
                parent ? parent.children << node : roots << node
              end
              analysis_content(Zaniah::UI::TreeView.new(roots, height: 300, label: t("プロトコル階層")).test_id("vk.stats.hierarchy"))
            else
              tabs = tables.map { |table| [table.type.to_s.upcase, statistics_table(table)] }
              analysis_content(Zaniah::UI::Tabs.new(tabs, selected: @statistics_tab || 0)
                .on_change { |index, *_| @statistics_tab = index }.test_id("vk.stats.tabs"))
            end
          end
        end
        refresh_analysis
      end

      def expert_info(displayed_only: false)
        return unless document
        controls = Zaniah::UI::Checkbox.new(t("表示中のパケットのみ"), value: displayed_only)
          .on_change { |value, *_| expert_info(displayed_only: value) }
        analysis_dialog(:expert_info, t("エキスパート情報"), controls, reopen: -> { expert_info(displayed_only: displayed_only) })
        @analysis_refresh = lambda do
          analysis_background(->(doc, *) { App::ExpertInfo.rows(doc, displayed_only: displayed_only) }) do |rows|
            table = analysis_table(rows, %i[severity code protocol count message]) do |row, event|
              select_packet(row.numbers.first) if event&.click_count.to_i >= 2
            end.test_id("vk.expert.table")
            analysis_content(table)
          end
        end
        refresh_analysis
      end

      def io_graph(interval: 1, expressions: [""], displayed_only: false)
        return unless document
        interval_control = Zaniah::UI::Select.new(App::IOGraph::INTERVALS.map { |value| [t("%{value}秒", value: value), value] }, value: interval, label: t("間隔"))
          .test_id("vk.io.interval")
        filters = Zaniah::UI::TextArea.new(expressions.join("\n"), rows: 2, label: t("系列の表示フィルタ（1行に1系列、空行は全件）")).test_id("vk.io.series")
        displayed = Zaniah::UI::Checkbox.new(t("表示中のパケットのみ"), value: displayed_only)
        redraw = lambda { io_graph(interval: interval, expressions: filters.value.split("\n", -1).uniq, displayed_only: displayed.value) }
        interval_control.on_change { |value, *_| interval = value; redraw.call }
        displayed.on_change { redraw.call }
        controls = Zaniah::Div.new.flex_col.gap(6).child(interval_control).child(filters).child(displayed)
          .child(Zaniah::UI::Button.new(t("系列を適用")).test_id("vk.io.apply").on_click { redraw.call })
        analysis_dialog(:io_graph, t("I/O グラフ"), controls, reopen: redraw)
        @analysis_refresh = lambda do
          analysis_background(->(doc, cancelled) { App::IOGraph.build(doc, interval: interval, series: expressions, displayed_only: displayed_only, cancelled: cancelled) }) do |series|
            if series.first.points.empty?
              analysis_content(Zaniah::UI::Label.new(t("表示するパケットがありません。")))
              next
            end
            values = series.each_with_index.to_h { |item, index| [item.expression.empty? ? t("全件 %{index}", index: index + 1) : item.expression, item.points.map(&:packets)] }
            omitted = series.first&.omitted_intervals || 0
            content = Zaniah::Div.new.flex_col.gap(4)
            content.child(Zaniah::UI::Label.new(t("先頭の%{count}区間を省略しています。間隔を広げると全期間を表示できます。", count: omitted), wrap: :word)) if omitted.positive?
            content.child(Zaniah::UI::LineChart.new(values, width: 660, height: 220, label: t("区間ごとのパケット数")).test_id("vk.io.chart"))
            analysis_content(content)
          end
        end
        refresh_analysis
      end

      def follow_tcp_stream(stream_id = nil, format: :ascii, direction: nil)
        return unless document
        stream_id ||= selected_number && document.annotations[selected_number][:tcp_stream]
        return show_error(Vanken::Error.new(t("TCPストリームを持つパケットを選択してください。"))) unless stream_id && stream_id >= 0
        number = Zaniah::UI::NumberInput.new(stream_id.to_s, min: 0, label: t("ストリーム番号")).test_id("vk.follow.number")
        formats = Zaniah::UI::Select.new([["ASCII", :ascii], [t("16進ダンプ"), :hex], [t("生データ（保存用）"), :raw]], value: format, label: t("表示形式"))
        directions = Zaniah::UI::Select.new([[t("両方向"), nil], [t("クライアント → サーバー"), 0], [t("サーバー → クライアント"), 1]], value: direction, label: t("方向"))
        reload = lambda do
          value = number.number
          raise ArgumentError, t("ストリーム番号は0以上の整数で指定してください。") unless value && value >= 0 && value == value.to_i
          follow_tcp_stream(value.to_i, format: format, direction: direction)
        rescue ArgumentError => error
          show_error(error)
        end
        formats.on_change { |value, *_| format = value; reload.call }
        directions.on_change { |value, *_| direction = value; reload.call }
        search = Zaniah::UI::TextField.new("", label: t("文字列検索")).test_id("vk.follow.search")
        controls = Zaniah::Div.new.flex_col.gap(6)
          .child(Zaniah::Div.new.flex_row.gap(6).child(number).child(formats).child(directions)
            .child(Zaniah::UI::Button.new(t("表示")).on_click { reload.call }))
          .child(Zaniah::Div.new.flex_row.gap(6).child(search)
            .child(Zaniah::UI::Button.new(t("次を検索")).on_click { search_stream(search.value) })
            .child(Zaniah::UI::Button.new(t("保存")).test_id("vk.follow.save").on_click { save_stream_dialog(format: format, direction: direction) })
            .child(Zaniah::UI::Button.new(t("このストリームを除外")).test_id("vk.follow.exclude").on_click do
              set_filter("!(tcp.stream == #{stream_id})")
              apply_filter
              dismiss_dialog
            end))
        analysis_dialog(:follow_tcp_stream, t("TCP ストリームを追跡"), controls, reopen: reload)
        @analysis_refresh = lambda do
          analysis_background(->(doc, cancelled) { Gateway::Stream.new(doc, stream_id, cancelled: cancelled) }) do |stream|
            @follow_stream = stream
            chunks = stream.preview(format: format == :raw ? :hex : format, direction: direction)
            runs = chunks.map { |chunk| {text: chunk.text, color: Zaniah::Color.parse(chunk.direction.zero? ? "#ce3e52" : "#277bcc")} }
            @follow_text = Zaniah::UI::RichText.new(runs).test_id("vk.follow.text")
            content = Zaniah::Div.new.flex_col.gap(6).child(Zaniah::UI::Label.new(stream.nodes.join(" ↔ "), wrap: :word))
            if stream.byte_size(direction: direction) > Gateway::Stream::DISPLAY_LIMIT
              content.child(Zaniah::UI::Label.new(t("表示は16 MiBまでです。保存は全量を含みます。"), wrap: :word))
            end
            content.child(Zaniah::ScrollView.new.h(280).child(@follow_text))
            analysis_content(content)
          end
        end
        refresh_analysis
      rescue ArgumentError => error
        show_error(error)
      end

      def search_stream(value)
        return if value.empty? || !@follow_text
        index = @follow_text.text.index(value, @follow_text.selection.head)
        index ||= @follow_text.text.index(value)
        return unless index
        @follow_text.selection = Zaniah::TextSelection.new(index, index + value.bytesize)
        @window.request_frame
      end

      def save_stream_dialog(format: :raw, direction: nil)
        return unless @follow_stream
        stream = @follow_stream
        export_path("stream-#{stream.stream_id}.#{format == :raw ? 'bin' : 'txt'}") do |path|
          analysis_background(->(_doc, cancelled) { stream.save(path, format: format, direction: direction, cancelled: cancelled) }) { dismiss_dialog }
        end
      end

      def export_packets = export_dialog(false)
      def export_dissections = export_dialog(true)

      def export_dialog(dissections = false, scope: :all, format: nil, range_value: "", exclude_ignored: false)
        return unless document
        format ||= dissections ? :json : :pcapng
        range = Zaniah::UI::TextField.new(range_value, label: t("範囲（1-10,20,30-）")).test_id("vk.export.range")
        ignored = Zaniah::UI::Checkbox.new(t("無視したパケットを除外"), value: exclude_ignored)
        scope_control = Zaniah::UI::Select.new([[t("全件"), :all], [t("表示中"), :displayed], [t("選択"), :selected], [t("マーク済み"), :marked], [t("最初と最後のマークの間"), :between_marks], [t("範囲指定"), :range]], value: scope, label: t("対象"))
          .on_change { |value, *_| scope = value }
        formats = dissections ? %i[json ndjson text csv] : %i[pcapng pcap]
        content = Zaniah::Div.new.flex_col.gap(8).child(scope_control).child(range).child(ignored)
          .child(Zaniah::UI::Select.new(formats, value: format, label: t("形式")).on_change { |value, *_| format = value })
          .child(Zaniah::UI::Button.new(t("エクスポート")).test_id("vk.export.save").on_click do
            numbers = Gateway::Exporter.new(document).numbers(scope: scope, range: range.value, selected: selected_number, exclude_ignored: ignored.value)
            columns = @table.columns
            columns = columns.map { |column| column[:key] == :time ? column.merge(format: @preferences.get("packet_list.time_format").to_sym) : column }
            export_path("packets.#{format == :text ? 'txt' : format}") do |path|
              analysis_background(->(doc, cancelled) { Gateway::Exporter.new(doc).write(path, format: format, numbers: numbers, columns: columns, cancelled: cancelled) }) { dismiss_dialog }
            end
          rescue StandardError => error
            show_error(error)
          end)
        analysis_dialog(:export, t("%{kind}のエクスポート", kind: t(dissections ? "解析結果" : "パケット")), content, reopen: -> { export_dialog(dissections, scope: scope, format: format, range_value: range.value, exclude_ignored: ignored.value) })
      end

      def file_properties
        return unless document
        controls = Zaniah::UI::Button.new(t("SHA-256を計算")).test_id("vk.properties.sha256").disabled(!document.path || !File.file?(document.path))
          .on_click do
            analysis_background(->(doc, *) { Digest::SHA256.file(doc.path).hexdigest }) do |digest|
              @analysis_results.child(Zaniah::UI::Label.new("SHA-256: #{digest}", wrap: :word))
              @window.request_frame
            end
          end
        analysis_dialog(:file_properties, t("キャプチャファイルのプロパティ"), controls, reopen: -> { file_properties })
        @analysis_refresh = lambda do
          analysis_background(->(doc, cancelled) { capture_properties(doc, cancelled) }) do |properties|
            analysis_content(Zaniah::Div.new.flex_col.gap(4).children(properties.map { |label, value| Zaniah::UI::Label.new("#{label}: #{value}", wrap: :word) }))
          end
        end
        refresh_analysis
      end

      private

      def analysis_dialog(kind, title, controls, reopen: nil)
        dismiss_dialog
        @analysis_results = Zaniah::Div.new.flex_col.gap(4).child(Zaniah::UI::Label.new(t("集計中…")))
        @dialog_kind = kind
        @dialog_reopen = reopen
        body = Zaniah::Div.new.flex_col.gap(8).child(controls).child(@analysis_results)
        @dialog = Zaniah::UI::Dialog.new(body, title: title, width: [760, @window.content_size.width - 32].min, close_label: t("閉じる"))
          .on_close { dismiss_dialog }.test_id("vk.#{kind}")
        @window.request_frame
      end

      def analysis_background(operation, &publish)
        return if @analysis_running || @closing || !document
        doc, generation = document, @analysis_generation || 0
        @analysis_running = true
        @analysis_task = @app.executor.background do
          cancelled = -> { @closing || generation != (@analysis_generation || 0) || !document.equal?(doc) }
          next if cancelled.call
          value = operation.call(doc, cancelled)
          @app.executor.post do
            next if cancelled.call
            @analysis_running = false
            publish.call(value)
          end
        rescue StandardError => error
          @app.executor.post do
            next if cancelled.call
            @analysis_running = false
            show_error(error)
          end
        end
      end

      def analysis_content(content)
        @analysis_results.children.clear
        @analysis_results.child(content)
        @window.request_frame
      end

      def analysis_table(rows, keys, &selection)
        labels = {severity: "重大度", code: "コード", protocol: "プロトコル", count: "件数", message: "メッセージ",
          addr_a: "アドレス A", port_a: "ポート A", addr_b: "アドレス B", port_b: "ポート B", packets_ab: "パケット A → B", packets_ba: "パケット B → A", bytes_ab: "バイト A → B", bytes_ba: "バイト B → A", duration_ns: "期間（ns）",
          address: "アドレス", port: "ポート", packets_tx: "送信パケット", packets_rx: "受信パケット", bytes_tx: "送信バイト", bytes_rx: "受信バイト"}
        label = t({expert_info: "エキスパート情報", conversations: "会話", endpoints: "端点"}.fetch(@dialog_kind, "統計"))
        source = AnalysisRows.new(rows.dup)
        table = Zaniah::UI::VirtualTable.new(source, columns: keys.map { |key| {key: key, label: t(labels.fetch(key, key.to_s)), width: key == :message ? 400 : 130} }, height: 300, label: label)
          .on_sort { |key, direction, _| source.sort(key, direction); table.invalidate }
        table.on_select { |index, event, *_| selection.call(source[index], event) } if selection
        table
      end

      def statistics_table(statistics)
        rows = statistics.rows
        columns = statistics.kind == :conv ? %i[addr_a port_a addr_b port_b packets_ab packets_ba bytes_ab bytes_ba duration_ns] : %i[address port packets_tx packets_rx bytes_tx bytes_rx]
        selected = nil
        table = analysis_table(rows, columns) { |row, _| selected = row }
        content = Zaniah::Div.new.flex_col.gap(6)
          .child(Zaniah::ScrollView.new(axis: :horizontal).h(300).child(table.w(columns.size * 130)))
        content.child(Zaniah::UI::Label.new(t("メモリ上限により%{count}行が省略されました。", count: statistics.evicted), wrap: :word)) if statistics.evicted.positive?
        content.child(Zaniah::Div.new.flex_row.gap(6)
          .child(Zaniah::UI::Button.new(t("フィルタとして適用")).on_click do
            next unless selected
            set_filter(statistics_filter(statistics, selected))
            apply_filter
            dismiss_dialog
          end)
          .child(Zaniah::UI::Button.new(t("TCP ストリームを追跡")).disabled(statistics.type != :tcp).on_click do
            next unless selected && statistics.type == :tcp
            expression = statistics_filter(statistics, selected)
            doc = document
            program = Core::DisplayFilter.compile(expression, catalog: doc.catalog)
            analysis_background(->(*) { (1..doc.count).find { |number| program.match?(doc.view(number)) } }) do |number|
              follow_tcp_stream(doc.annotations[number][:tcp_stream]) if number
            end
          end))
        content
      end

      def statistics_filter(table, row)
        protocol = table.type.to_s
        if table.kind == :endpoints
          address = %i[tcp udp].include?(table.type) ? (row.address.include?(":") ? "ipv6" : "ip") : protocol
          expression = "#{address}.addr == #{row.address}"
          return %i[tcp udp].include?(table.type) ? "#{expression} && #{protocol}.port == #{row.port}" : expression
        end
        address = %i[tcp udp].include?(table.type) ? (row.addr_a.include?(":") ? "ipv6" : "ip") : protocol
        forward = "#{address}.src == #{row.addr_a} && #{address}.dst == #{row.addr_b}"
        backward = "#{address}.src == #{row.addr_b} && #{address}.dst == #{row.addr_a}"
        if %i[tcp udp].include?(table.type)
          forward += " && #{protocol}.srcport == #{row.port_a} && #{protocol}.dstport == #{row.port_b}"
          backward += " && #{protocol}.srcport == #{row.port_b} && #{protocol}.dstport == #{row.port_a}"
        end
        "(#{forward}) || (#{backward})"
      end

      def export_path(default_name, &operation)
        return path_dialog(t("エクスポート先"), &operation) if @backend == :tui
        path = @window.prompt_for_paths(save: true, default_name: default_name)&.first
        operation.call(path) if path
      rescue StandardError => error
        show_error(error)
      end

      def capture_properties(doc, cancelled)
        count, bytes, captured, first, last = doc.count, 0, 0, nil, nil
        interfaces = Hash.new(0)
        (1..count).each do |number|
          raise Vanken::Error, "operation cancelled" if cancelled.call
          metadata = doc.store.metadata(number)
          bytes += metadata[:original_length]
          captured += metadata[:caplen]
          first = [first || metadata[:timestamp_ns], metadata[:timestamp_ns]].min
          last = [last || metadata[:timestamp_ns], metadata[:timestamp_ns]].max
          interfaces[metadata[:interface]&.fetch("name", nil) || t("未記録")] += 1
        end
        duration = first && last ? (last - first) / 1e9 : 0
        values = {t("ファイル") => doc.path || t("未保存"), t("パケット") => count, t("期間（秒）") => duration,
          t("合計（bytes）") => bytes, t("保存済み（bytes）") => captured,
          t("平均pps") => duration.positive? ? (count / duration).round(3) : 0,
          t("平均bps") => duration.positive? ? (bytes * 8 / duration).round(3) : 0}
        interfaces.each { |name, packets| values[t("インタフェース %{name}", name: name)] = t("%{count} パケット", count: packets) }
        doc.capture_stats.each { |key, value| values[t("取得統計 %{key}", key: key)] = value }
        values
      end
    end
  end
end
