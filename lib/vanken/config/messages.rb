# frozen_string_literal: true
# rbs_inline: enabled

module Vanken
  module Config
    module Messages
      EN = {
        "TCP ストリームを追跡" => "Follow TCP Stream", "別プロトコルとして解析" => "Decode As",
        "注記" => "note", "警告" => "warning", "エラー" => "error", "トラフィック" => "traffic",
        "開く" => "Open", "名前を付けて保存" => "Save as", "ファイルを閉じる" => "Close file", "再読み込み" => "Reload",
        "終了" => "Quit", "設定" => "Preferences", "キャプチャ開始／停止" => "Start or stop capture", "キャプチャ再開" => "Restart capture",
        "フィルタを適用" => "Apply filter", "フィルタをクリア" => "Clear filter", "フィルタ履歴" => "Filter history", "フィルタを保存" => "Save filter",
        "選択した項目でフィルタ" => "Filter by selected field", "選択した項目のフィルタを準備" => "Prepare filter from selected field",
        "表示する列" => "Visible columns", "末尾追従" => "Follow tail", "末尾追従 ✓" => "Follow tail ✓",
        "拡大" => "Zoom in", "縮小" => "Zoom out", "標準サイズ" => "Reset zoom",
        "前のパケット" => "Previous packet", "次のパケット" => "Next packet", "最初のパケット" => "First packet", "最後のパケット" => "Last packet",
        "パケットへ移動" => "Go to packet", "項目をフィルタとしてコピー" => "Copy field as filter",
        "パケット検索" => "Find packet", "次を検索" => "Find next", "前を検索" => "Find previous",
        "マーク／解除" => "Mark or unmark packet", "表示中をすべてマーク" => "Mark all displayed packets", "すべてのマークを解除" => "Unmark all packets",
        "無視／解除" => "Ignore or unignore packet", "時刻基準／解除" => "Set or unset time reference", "同一会話の前" => "Previous in conversation", "同一会話の次" => "Next in conversation",
        "色付けルール" => "Coloring rules", "色付け" => "Packet coloring", "エキスパート情報" => "Expert information",
        "プラグイン再読み込み" => "Reload plugins", "ディセクタプラグイン" => "Dissector plugins", "キャプチャファイルのプロパティ" => "Capture file properties",
        "プロトコル階層" => "Protocol hierarchy", "会話" => "Conversations", "端点" => "Endpoints", "I/O グラフ" => "I/O graph",
        "指定パケットのエクスポート" => "Export specified packets", "解析結果のエクスポート" => "Export dissections", "コマンドパレット" => "Command palette", "プロファイル" => "Profiles",
        "時刻: %{name}" => "Time: %{name}", "テーマ: %{name}" => "Theme: %{name}", "選択項目" => "Selected field", "選択項目を除外" => "Exclude selected field",
        "適用: %{label}" => "Apply: %{label}", "準備: %{label}" => "Prepare: %{label}", "16 進数" => "Hexadecimal", "テキスト" => "Text", "ダンプ" => "Hex dump",
        "エスケープした文字列" => "Escaped text", "バイトをコピー: %{label}" => "Copy bytes: %{label}",
        "ファイル" => "File", "編集" => "Edit", "表示" => "View", "時刻形式" => "Time format", "テーマ" => "Theme", "移動" => "Go",
        "キャプチャ" => "Capture", "フィルタ" => "Filter", "選択項目を適用" => "Apply selected field", "選択項目から準備" => "Prepare from selected field",
        "分析" => "Analyze", "統計" => "Statistics", "ヘルプ" => "Help", "表示中のパケットのみ" => "Displayed packets only",
        "%{value}秒" => "%{value} s", "間隔" => "Interval", "系列の表示フィルタ（1行に1系列、空行は全件）" => "Series display filters (one per line; blank means all packets)",
        "系列を適用" => "Apply series", "表示するパケットがありません。" => "There are no packets to display.", "全件 %{index}" => "All packets %{index}",
        "先頭の%{count}区間を省略しています。間隔を広げると全期間を表示できます。" => "The first %{count} intervals are omitted. Select a wider interval to show the entire capture.",
        "TCPストリームを持つパケットを選択してください。" => "Select a packet with a TCP stream.", "ストリーム番号" => "Stream number",
        "16進ダンプ" => "Hex dump", "生データ（保存用）" => "Raw data (for saving)", "表示形式" => "Display format", "両方向" => "Both directions",
        "クライアント → サーバー" => "Client → server", "サーバー → クライアント" => "Server → client", "方向" => "Direction",
        "ストリーム番号は0以上の整数で指定してください。" => "The stream number must be a nonnegative integer.", "文字列検索" => "Find text",
        "保存" => "Save", "このストリームを除外" => "Exclude this stream", "表示は16 MiBまでです。保存は全量を含みます。" => "The display is limited to 16 MiB. Saving includes the entire stream.",
        "範囲（1-10,20,30-）" => "Range (1-10,20,30-)", "無視したパケットを除外" => "Exclude ignored packets", "全件" => "All packets", "表示中" => "Displayed",
        "選択" => "Selected", "マーク済み" => "Marked", "最初と最後のマークの間" => "Between first and last marks", "範囲指定" => "Packet range", "対象" => "Scope",
        "形式" => "Format", "エクスポート" => "Export", "解析結果" => "Dissections", "パケット" => "Packets", "%{kind}のエクスポート" => "Export %{kind}",
        "SHA-256を計算" => "Calculate SHA-256", "集計中…" => "Calculating…", "メモリ上限により%{count}行が省略されました。" => "%{count} rows were omitted because of the memory limit.",
        "フィルタとして適用" => "Apply as filter", "エクスポート先" => "Export destination", "未記録" => "Not recorded", "未保存" => "Unsaved",
        "期間（秒）" => "Duration (seconds)", "合計（bytes）" => "Total bytes", "保存済み（bytes）" => "Captured bytes", "平均pps" => "Average packets/s", "平均bps" => "Average bits/s",
        "インタフェース %{name}" => "Interface %{name}", "取得統計 %{key}" => "Capture statistics %{key}",
        "検索内容" => "Search query", "表示フィルタ" => "Display filter", "16 進" => "Hex", "文字列" => "String", "正規表現" => "Regular expression",
        "パケット一覧" => "Packet list", "パケット詳細" => "Packet details", "パケットバイト" => "Packet bytes", "検索対象" => "Search in", "キャンセル" => "Cancel",
        "一致するパケットはありません。" => "No matching packets were found.", "ルール" => "Rule", "名前" => "Name", "有効" => "Enabled",
        "ライト" => "Light", "ダーク" => "Dark", "文字" => "Text color", "背景" => "Background", "削除" => "Delete", "追加" => "Add", "新しいルール" => "New rule",
        "%{theme} %{part}" => "%{theme} %{part}", "インポート" => "Import", "適用" => "Apply", "色付けルールの読み込み先" => "Import coloring rules", "色付けルールの保存先" => "Export coloring rules",
        "インタフェース" => "Interface", "キャプチャフィルタ (BPF)" => "Capture filter (BPF)", "バッファサイズ (bytes)" => "Buffer size (bytes)",
        "停止件数 (0: 無制限)" => "Stop after packet count (0: unlimited)", "停止までの秒数 (0: 無制限)" => "Stop after seconds (0: unlimited)", "停止サイズ (bytes、0: 無制限)" => "Stop after bytes (0: unlimited)",
        "リング保存先 (空欄: 保存しない)" => "Ring file path (blank: disabled)", "リングファイル上限 (bytes)" => "Ring file size limit (bytes)", "リング切替間隔 (秒)" => "Ring rotation interval (seconds)", "リングファイル数" => "Ring file count",
        "プロミスキャスモード" => "Promiscuous mode", "送受信" => "Inbound and outbound", "受信" => "Inbound", "送信" => "Outbound",
        "インタフェースを取得中です。" => "Loading interfaces…", "GUI は通常ユーザーで動作し、取得ヘルパーに必要な権限を渡します。" => "The application runs as your user and grants the capture helper the required permissions.",
        "開始" => "Start", "停止" => "Stop", "再開" => "Restart", "キャプチャオプション" => "Capture options", "時刻表示" => "Time display", "文字を小さく" => "Smaller text", "文字を大きく" => "Larger text",
        "ファイルを開く" => "Open file", "キャプチャを停止してから操作してください。" => "Stop the capture before continuing.", "キャプチャ中" => "Capturing",
        "このキャプチャはまだ保存されていません。" => "This capture has not been saved.", "破棄" => "Discard", "キャプチャを保存しますか？" => "Save this capture?",
        "指定したパケットは表示されていません" => "The specified packet is not displayed", "%{message} (位置 %{position})" => "%{message} (position %{position})",
        "フィルタとしてコピー" => "Copy as filter", "フィルタを準備" => "Prepare filter", "フィルタの名前" => "Filter name",
        "プロファイルの管理" => "Manage profiles", "複製" => "Duplicate", "新しいプロファイル名" => "New profile name", "新規作成" => "Create profile", "例: udp.port==8443,dns" => "Example: udp.port==8443,dns",
        "Ruby ディセクタのパス" => "Ruby dissector path", "Ruby プラグインはユーザー権限で任意のコードを実行します。信頼するファイルだけを読み込んでください。\n%{paths}" => "Ruby plugins can execute arbitrary code as your user. Load only files you trust.\n%{paths}",
        "信頼して読み込む" => "Trust and load", "プラグインの確認" => "Confirm plugins", "コマンドを検索" => "Search commands", "解析" => "Analysis", "名前解決" => "Name resolution",
        "キャプチャファイルを開くか、インタフェースを選んで開始してください" => "Open a capture file or select an interface to start capturing.",
        "読み込み中" => "Loading", "%{state} %{count} / %{total}   表示 %{displayed}   ドロップ %{dropped}" => "%{state} %{count} / %{total}   Displayed %{displayed}   Dropped %{dropped}",
        "操作を完了できません" => "The operation could not be completed", "読み込みを中止" => "Cancel loading", "クリア" => "Clear", "履歴" => "History",
        "パケットキャプチャを開くか、インタフェースを選択してキャプチャを開始します。" => "Open a packet capture or select an interface to start capturing.",
        "キャプチャファイルを開く" => "Open capture file", "インタフェースを選択" => "Select interface",
        "上へ移動" => "Move up", "下へ移動" => "Move down", "項目名" => "Column name", "表示フィールド" => "Display field", "列幅" => "Column width",
        "列として適用" => "Apply as column", "カスタム列を追加" => "Add custom column", "カスタム列" => "Custom columns", "列の名前" => "Column label", "フィールド名" => "Field name",
        "時刻" => "Time", "送信元" => "Source", "宛先" => "Destination", "プロトコル" => "Protocol", "長さ" => "Length", "情報" => "Info",
        "重大度" => "Severity", "コード" => "Code", "件数" => "Count", "メッセージ" => "Message", "アドレス A" => "Address A", "ポート A" => "Port A", "アドレス B" => "Address B", "ポート B" => "Port B",
        "パケット A → B" => "Packets A → B", "パケット B → A" => "Packets B → A", "バイト A → B" => "Bytes A → B", "バイト B → A" => "Bytes B → A",
        "アドレス" => "Address", "ポート" => "Port", "送信パケット" => "Transmitted packets", "受信パケット" => "Received packets", "送信バイト" => "Transmitted bytes", "受信バイト" => "Received bytes", "期間（ns）" => "Duration (ns)",
        "言語" => "Language", "文字サイズ" => "Font size", "時刻の精度" => "Time precision", "自動スクロール" => "Autoscroll", "行キャッシュ容量" => "Row cache size",
        "チェックサム検証" => "Verify checksums", "解析メモリ上限（MiB）" => "Analysis memory limit (MiB)", "フロー数上限" => "Maximum flows", "ワーカー数" => "Workers",
        "キャプチャ方式" => "Capture backend", "ヘルパー起動方式" => "Helper launcher", "解決タイムアウト（秒）" => "Resolution timeout (seconds)", "名前キャッシュ容量" => "Name cache size",
        "保存せずに閉じる" => "Close without saving", "復旧可能なセッション" => "Recoverable sessions", "復旧" => "Recover", "一時セッションを復旧しますか？" => "Recover temporary sessions?",
        "相対時刻" => "Relative time", "絶対時刻" => "Absolute time", "前パケットとの差" => "Delta from previous packet", "前表示パケットとの差" => "Delta from previous displayed packet", "エポック時刻" => "Epoch time",
        "システム設定" => "System", "ハイコントラスト" => "High contrast", "ミリ秒" => "Milliseconds", "マイクロ秒" => "Microseconds", "ナノ秒" => "Nanoseconds",
        "前回のキャプチャを復旧" => "Recover previous capture",
        "%{label} %{count} / %{total}   表示 %{displayed}   ドロップ %{dropped}%{progress}" => "%{label} %{count} / %{total}   Displayed %{displayed}   Dropped %{dropped}%{progress}",
        "幅" => "Width", "列名 (空欄: フィールド名)" => "Column label (blank: field name)", "幅は40から4096の範囲で指定してください" => "Width must be between 40 and 4096",
        "%{protocol}   %{packets} パケット   %{bytes} bytes   %{percent}%" => "%{protocol}   %{packets} packets   %{bytes} bytes   %{percent}%",
        "区間ごとのパケット数" => "Packets per interval", "%{count} パケット" => "%{count} packets", "キャプチャファイル" => "Capture files", "閉じる" => "Close",
        "取得バッファ (bytes)" => "Capture buffer (bytes)", "取得方向" => "Capture direction",
        "自動停止: パケット数 (0: 無効)" => "Stop after packet count (0: disabled)", "自動停止: 秒 (0: 無効)" => "Stop after seconds (0: disabled)", "自動停止: bytes (0: 無効)" => "Stop after bytes (0: disabled)",
        "リング保存先 (空欄: 無効)" => "Ring file path (blank: disabled)", "リング: ファイルごとのbytes" => "Ring: bytes per file", "リング: 秒" => "Ring: seconds", "リング: 保持ファイル数" => "Ring: retained files",
        "検索形式" => "Search mode", "キャプチャ操作" => "Capture controls", "日本語" => "Japanese", "英語" => "English", "自動" => "Automatic", "直接" => "Direct",
        "マーク" => "Mark", "マークを解除" => "Unmark", "無視" => "Ignore", "無視を解除" => "Unignore", "時刻基準にする" => "Set time reference", "時刻基準を解除" => "Unset time reference", "双方向" => "Both directions", "フィルタ履歴はまだありません。" => "There is no filter history yet."
      }.freeze #: Hash[String, String]
      JA = EN.invert.freeze #: Hash[String, String]

      # @rbs (String text, ?language: String, **untyped values) -> String
      def self.translate(text, language: "ja", **values)
        dictionary = case language
        when "ja" then JA
        when "en" then EN
        else raise Vanken::ConfigError, "invalid language: #{language}"
        end
        dictionary.fetch(text, text).gsub(/%\{(\w+)\}/) { values.fetch(Regexp.last_match(1).to_sym).to_s }
      end
    end
  end
end
