# frozen_string_literal: true

require "spec_helper"
require "vanken/ui/application"
require_relative "../support/packets"

RSpec.describe "Localized accessible screens" do
  NAMED_ROLES = %i[button textbox searchbox combobox checkbox radio switch slider spinbutton toolbar listitem treeitem tab columnheader table tree radiogroup list dialog].freeze

  DIALOG_CONTROLS = {
    path: [[:textbox, "パケットへ移動"]], capture_options: [[:button, "開始"], [:combobox, "インタフェース"]],
    search: [[:textbox, "検索内容"], [:radiogroup, "検索形式"]], history: [[:text, "フィルタ履歴はまだありません。"]],
    coloring: [[:button, "適用"], [:textbox, "名前"]], columns: [[:button, "追加"], [:textbox, "フィールド名"]],
    preferences: [[:table, "表示"]], profiles: [[:button, "新規作成"]], decode_as: [[:textbox, "例: udp.port==8443,dns"]],
    plugins: [[:button, "追加"]], plugin_trust: [[:button, "信頼して読み込む"]], recovery: [[:button, "復旧"]],
    unsaved: [[:button, "破棄"]], capturing: [[:button, "停止"]], search_result: [[:text, "一致するパケットはありません。"]],
    error: [[:text, "Example failure"]], command_palette: [[:searchbox, "コマンドを検索"], [:list, "コマンドパレット"]],
    protocol_hierarchy: [[:tree, "プロトコル階層"]], conversations: [[:table, "会話"]], endpoints: [[:table, "端点"]],
    expert_info: [[:table, "エキスパート情報"]], io_graph: [[:image, "区間ごとのパケット数"]],
    follow_tcp_stream: [[:textbox, "文字列検索"]], export: [[:button, "エクスポート"], [:textbox, "範囲（1-10,20,30-）"]],
    file_properties: [[:button, "SHA-256を計算"]]
  }.freeze

  before do
    @directory = Dir.mktmpdir
    @preferences = Vanken::Config::Preferences.new(directory: @directory)
    @preferences.set("appearance.language", "ja")
    @preferences.set("appearance.theme", "high_contrast")
    @preferences.set("layout.width", 1100)
    @preferences.set("layout.height", 850)
    @ui = Vanken::UI::Application.new(backend: :headless, preferences: @preferences)
    # Public scene rendering still performs layout, focus dispatch, and accessibility.
    allow(@ui.window).to receive(:render).and_wrap_original do |original, element, **options|
      original.call(element, **options, present: false)
    end
    @doc = Vanken::App::Document.new(process_analysis: false).ingest([
      frame(tcp_bytes(seq: 100, flags: 2)),
      frame(tcp_bytes(seq: 101, flags: 16, payload: "hello"), number: 2)
    ], live: true).wait
    plugin_path = File.join(@directory, "example_plugin.rb")
    File.write(plugin_path, "# trusted only after confirmation\n")
    @ui.analysis_settings.register_plugin(plugin_path)
    @ui.attach_document(@doc)
    @ui.instance_variable_set(:@interface_infos, [{name: "lo", description: "Loopback", linktype: 1}])
  end

  after do
    @ui&.close
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  def settle(id = nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      @ui.app.executor.drain
      @ui.window.tick
      snapshot = Zaniah::Inspection.snapshot(@ui.window)
      return snapshot if !id || snapshot.find(test_id: id)
      raise "screen did not settle: #{@ui.dialog_kind}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.001)
    end
  end

  def audit(snapshot, required: nil)
    missing = snapshot.accessibility.query.filter_map do |node, path|
      [node.role, path] if NAMED_ROLES.include?(node.role) && node.label.to_s.strip.empty?
    end
    expect(missing).to be_empty, "unnamed controls in #{@ui.dialog_kind}: #{missing.inspect}"
    expect(snapshot.accessibility.query(role: :button)).not_to be_empty
    if @ui.dialog
      dialog = snapshot.accessibility.query(role: :dialog).find { |node, _| node.id == @ui.dialog.test_id }&.first
      expect(dialog).not_to be_nil
      body = Zaniah::Inspection::AccessibilitySnapshot.new(root: dialog)
      controls = required || DIALOG_CONTROLS.fetch(@ui.dialog_kind)
      controls.each do |role, text|
        expect(body.query(role: role, label: @ui.t(text))).not_to be_empty, "missing #{role} #{text} inside #{@ui.dialog_kind}"
      end
      if @ui.dialog_kind == :preferences && !required
        expect(body.query(role: :combobox, label: @ui.t("テーマ")).first.first.value).to eq(@ui.t("ハイコントラスト"))
        language = @preferences.get("appearance.language") == "ja" ? "日本語" : "English"
        expect(body.query(role: :combobox, label: @ui.t("言語")).first.first.value).to eq(@ui.t(language))
      end
    end
    expect(@ui.window.scene.commands).not_to be_empty
    if @preferences.get("appearance.language") == "en"
      labels = snapshot.accessibility.query.map { |node, _| node.label }.compact
      expect(labels.join(" ")).not_to match(/[\p{Hiragana}\p{Katakana}\p{Han}]/), "untranslated screen #{@ui.dialog_kind}"
    end
  end

  it "names controls on every screen in both languages and retranslates open dialogs without losing input" do
    %w[ja en].each do |language|
      @ui.dismiss_dialog
      @ui.apply_preference("appearance.language", language)
      @ui.attach_document(nil)
      audit(settle("vk.welcome"))
      @ui.attach_document(@doc)
      audit(settle)
      expect(@ui.app.actions.command(:open).title).to eq(language == "ja" ? "開く" : "Open")
      @ui.path_dialog("パケットへ移動", value: "2") { |path| @entered_path = path }
      audit(settle("vk.path.input"))
      @ui.apply_preference("appearance.language", language == "ja" ? "en" : "ja")
      snapshot = settle("vk.path.input")
      expect(snapshot.find(test_id: "vk.path.input").element.value).to eq("2")
      expect(snapshot.accessibility.query(role: :dialog, label: @ui.t("パケットへ移動"))).not_to be_empty
      @ui.apply_preference("appearance.language", language)
      screens = [
        [-> { @ui.capture_options(interface: "lo") }, "vk.capture.start"],
        [-> { @ui.find_packet }, "vk.search.query"],
        [-> { @ui.filter_history }, "vk.history"],
        [-> { @ui.coloring_dialog }, "vk.coloring.apply"],
        [-> { @ui.columns_dialog }, "vk.columns.add"],
        [-> { @ui.preferences_dialog }, "vk.preferences.appearance"],
        [-> { @ui.profiles_dialog }, "vk.profiles"],
        [-> { @ui.decode_as }, "vk.decode_as.rules"],
        [-> { @ui.plugins_dialog }, "vk.plugins"],
        [-> { @ui.reload_plugins }, "vk.plugins.trust"],
        [-> { @ui.recovery_dialog([@doc.store.directory]) }, "vk.recovery"],
        [-> { @ui.request_destructive { @destructive_called = true } }, "vk.unsaved"],
        [-> { @ui.search_result_dialog }, "vk.search_result"],
        [-> { @ui.show_error(Vanken::Error.new("Example failure")) }, "vk.error"],
        [-> { @ui.command_palette }, "vk.command_palette"],
        [-> { @ui.protocol_hierarchy }, "vk.stats.hierarchy"],
        [-> { @ui.conversations }, "vk.stats.tabs"],
        [-> { @ui.endpoints }, "vk.stats.tabs"],
        [-> { @ui.expert_info }, "vk.expert.table"],
        [-> { @ui.io_graph }, "vk.io.chart"],
        [-> { @ui.follow_tcp_stream(0) }, "vk.follow.text"],
        [-> { @ui.export_packets }, "vk.export.save"],
        [-> { @ui.export_dissections }, "vk.export.save"],
        [-> { @ui.file_properties }, "vk.properties.sha256"]
      ]
      screens.each do |operation, id|
        operation.call
        snapshot = settle(id)
        audit(snapshot)
        if @ui.dialog_kind == :preferences
          tabs = snapshot.where(type: Zaniah::UI::Tabs).first.element
          @ui.window.dispatcher.focus(tabs.focus_handle, origin: :keyboard)
          %w[packet_list capture analysis name_resolution].each do |group|
            expect(@ui.window.dispatcher.key("right")).to eq(:next_option)
            audit(settle("vk.preferences.#{group}"), required: [[:table, @ui.send(:setting_label, group)]])
            expect(@ui.window.dispatcher.focus_visible?).to be(true)
          end
        end
      end
      expect(@destructive_called).not_to be(true)
      allow(@ui.capture).to receive(:running?).and_return(true)
      @ui.request_destructive { @destructive_called = true }
      audit(settle("vk.capture.confirm"))
      allow(@ui.capture).to receive(:running?).and_call_original
    end
  end
end
