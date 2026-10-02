# Using Vanken

## Keyboard and terminal operation

The desktop and terminal views share the same commands. Use Tab and Shift+Tab to move between controls, Enter to activate, Escape to close dialogs, and arrow keys in lists. In the terminal and on Linux, use Ctrl for the shortcuts below; the native macOS window uses Command instead.

| Action | Shortcut |
| --- | --- |
| Open capture | Ctrl+O |
| Save as | Ctrl+Shift+S |
| Start or stop capture | Ctrl+E |
| Restart capture | Ctrl+Shift+R |
| Preferences | Ctrl+Shift+P |
| Command palette | Ctrl+Shift+K |
| Find packet / next / previous | Ctrl+F / Ctrl+N / Ctrl+B |
| Mark / ignore / time reference | Ctrl+M / Ctrl+D / Ctrl+T |
| Previous / next packet | Alt+Up / Alt+Down |
| Previous / next in conversation | Ctrl+, / Ctrl+. |
| Go to packet | Ctrl+G |
| Follow TCP Stream | Ctrl+Alt+Shift+T |
| Decode As | Ctrl+Shift+U |
| Reload plugins | Ctrl+Shift+L |
| Quit | Ctrl+Q |

Terminals differ in the keys they transmit. Use the command palette for a command whose shortcut is intercepted by the terminal. Type an action name and use Up/Down and Enter to run it. Column movement, width, and visibility have controls in the column editor, so they do not require dragging.

## Profiles and settings

Preferences change the appearance, packet list, acquisition defaults, analysis limits, and optional name resolution. The language defaults to Japanese when `LANG` begins with `ja`, and English otherwise. Switching language rebuilds the current screen. High contrast is available from the theme menu or Preferences.

Create, duplicate, delete, and switch profiles from Preferences or the Profiles command. The default profile lives in the configuration directory; other profiles live under `profiles/NAME`. Each has `preferences.yml`, `columns.yml`, `coloring_rules.yml`, `filters.yml`, `decode_as.yml`, and `plugins.yml`. Configuration uses schema version 1, safe YAML, and atomic saves. Recent-file history and window geometry are shared outside profiles.

Stop acquisition before changing profiles or dissectors. Changes to analysis preferences during acquisition or file loading wait until it finishes. Reanalysis keeps the original bytes, marks, ignored packets, time references, and current selection, then refreshes summaries, details, and filters. Registered Ruby plugins execute with your account's permissions and require a trust confirmation before their first load.

## Exporting and following streams

Export all analyzed packets, displayed packets, the selected packet, marked packets, the range between the first and last marks, or explicit ranges such as `1-10,15,20-`. An option excludes ignored packets. pcapng preserves interface metadata; pcap requires compatible link types. Ordinary Save includes all durable packets, including packets still awaiting analysis.

JSON follows redhound's packet schema; NDJSON writes one packet per line. CSV exports visible columns, including custom fields. Text exports the protocol tree. Outputs are written to a temporary file and replace the destination only after completion.

Follow TCP Stream removes duplicate retransmissions, handles sequence wrap and out-of-order segments, and displays missing-data markers. The display preview is limited to 16 MiB; saving reads the full reconstructed stream. Raw saving omits missing bytes rather than inventing data.

## Limits and recovery

I/O graphs offer intervals of 0.01, 0.1, 1, 10, and 60 seconds. They show at most the latest 100,000 intervals and report omitted earlier intervals; choose a longer interval for long captures. Custom-column cells show at most 16 values and 4,096 bytes; the details and byte panes retain the full packet.

Acquisition can stop by packet count, duration, or byte count. Ring saving rotates pcapng files by size or time and replaces older slots after the configured file count. A size limit may be crossed by the packet that triggers rotation; packets are never split across files.

After an interrupted capture, the next start offers recovery or discard for owned, inactive session directories. Recovery reconstructs the analysis and keeps the capture unsaved until you save it. Sessions still used by a running process are excluded. A failed recovery preserves the raw session for another attempt.

See [capture permissions](../packaging/README.md) for administrator setup and [performance measurements](performance.md) for tested workloads and current limits.
