# User guide

For installation and a first capture, start with [Getting started](getting-started.md). This guide uses English menu labels; Preferences also offers Japanese.

## Read and inspect a capture

Open a pcap or pcapng file from the toolbar, File menu, recent-file list, or a file drop. Loading and analysis run in the background, so rows appear progressively. The status bar shows analyzed packets, retained packets, displayed packets, and capture drops. Analysis may lag behind acquisition; captured bytes remain available for saving while it catches up.

The packet list shows packet number, time, source, destination, protocol, length, and a summary. Packet numbers refer to the original capture, even after filtering or sorting. Select a row to load its protocol tree and bytes. Expand protocols in **Packet details**, then select a field to highlight its byte range. Select bytes to find the corresponding field. Reassembled or generated fields may have no range in the original frame.

Resize the split panes to suit the task. For a growing capture, **View → Follow tail** keeps the list at the newest rows; turn it off to inspect older packets. Opening another file, closing a capture, or quitting asks how to handle an unsaved capture.

## Filter the view

Enter a Vanken display filter below the toolbar and choose **Apply**, or press Enter while that field has focus. The input reports syntax errors and warnings. **Clear** removes the filter. Slow filters publish results progressively, and applying a different expression cancels the preceding scan.

```text
tcp.port == 443
ip.addr in {192.0.2.0/24, 198.51.100.5}
tcp.flags.syn == true && tcp.flags.ack == false
http.host contains "example"
frame.len > 1000 && !udp
```

Select a field in the details tree and open its context menu to **Apply as filter**, **Prepare filter**, or copy the expression. The apply and prepare submenus can replace the current expression or combine it using AND, OR, and negation. Preparing edits the input without changing the displayed rows.

Use **History** to reuse a recent expression. **Filter → Save filter** gives the current expression a name; saved filters also appear in history and completion. See the [display filter reference](filters.md) for types, missing and repeated fields, and all operators. Capture filters use BPF instead and are set before acquisition starts.

## Arrange columns and add a field

Select a column header to sort the list. Desktop controls also resize and reorder columns. **View → Visible columns** provides checkboxes, numeric widths, and movement buttons that work with a keyboard or in the terminal.

To compare a protocol field across packets:

1. Select the field in Packet details, for example `ip.ttl`.
2. Open its context menu and choose **Apply as column**.
3. Open **Visible columns** to change its width, position, or visibility, or remove the custom column.

You can also enter a field name and optional label in that dialog and choose **Add**. Widths range from 40 to 4,096. Custom columns sort using the field's type, so numbers and addresses are compared as values. For a repeated field, sorting uses its first value.

Column layouts persist in the current profile. A cell displays at most 16 values and 4,096 bytes; use the details and byte panes to inspect the full packet.

## Find, mark, and navigate packets

**Edit → Find packet** searches the currently displayed packets. Choose a display filter, hexadecimal bytes, a string, or a regular expression. String, hexadecimal, and regular-expression searches can target packet-list text, protocol details, or packet bytes. Select **Find next** or **Find previous** to repeat the search; it wraps around the displayed list. Clear the display filter first if you want to search the whole analyzed capture.

Use **Mark or unmark packet** to collect packets for later export. You can mark all displayed packets or clear all marks from the Edit menu. The display filter `frame.marked == true` shows your marked set.

**Ignore or unignore packet** records a flag without deleting captured bytes. Use `frame.ignored == false` to hide flagged packets, or enable **Exclude ignored packets** when exporting. Ordinary Save still includes their bytes.

**Go → Go to packet** selects an original packet number if it is currently displayed. Previous and next packet follow the displayed order. Previous and next in conversation move through the selected packet's TCP stream, skipping packets hidden by the display filter.

## Compare time and color related traffic

Choose **View → Time format** for relative time, absolute time, the delta from the previous captured packet, the delta from the previous displayed packet, or epoch time. Precision is configurable in Preferences.

Select a packet and use **Set or unset time reference** to make it a zero point for relative time. Later packet numbers use the most recent preceding reference; another reference begins a new relative interval. Toggle the same packet again to remove its reference.

Open **View → Coloring rules** to add or edit a named display-filter rule, enable or disable it, and choose foreground and background colors for light and dark themes. The first enabled matching rule wins, so move a specific rule above a broader one. Choose **Apply** to save edits. Rules can be imported and exported as YAML. **Packet coloring** toggles coloring without deleting the rules; high contrast preserves the theme's background.

## Follow a TCP stream

Select a TCP packet and choose **Analyze → Follow TCP Stream**, or use the packet context menu. The dialog shows the two directions in different colors. Change the stream number to inspect another stream, or limit the view to one direction.

Choose ASCII or hexadecimal output. **Raw data (for saving)** uses a hexadecimal preview and writes original reconstructed bytes when saved. Search for a string with **Find next**; repeating the search advances to another match and wraps at the end. **Exclude this stream** applies a display filter that hides it.

Reconstruction removes duplicate retransmissions, keeps the first captured bytes where segments overlap, handles sequence wrap and out-of-order segments, and displays missing-data markers. The preview is limited to 16 MiB. **Save** writes the full reconstructed stream in the selected format and direction; raw saving omits missing bytes instead of inventing them.

## Inspect diagnostics, statistics, and traffic rates

**Analyze → Expert information** groups diagnostics by severity, code, protocol, and message, with occurrence counts. Double-click an entry to select its first affected packet. The diagnostic count in the status bar also opens this view.

The Statistics menu provides:

| View | Use |
| --- | --- |
| Protocol hierarchy | Expand protocol paths to compare packet counts, bytes, and percentages. |
| Conversations | Compare address/port pairs, both traffic directions, and duration. |
| Endpoints | Compare per-address or per-port send and receive counts. |
| I/O graph | Compare packet counts per interval for one or more display-filter series. |
| Capture file properties | Inspect size, duration, rates, interfaces, and capture statistics; calculate SHA-256 for an existing capture file. |

Conversations and Endpoints have Ethernet, IPv4, IPv6, TCP, and UDP tabs. Select a row to apply its traffic as a display filter; a selected TCP conversation can also open Follow TCP Stream. **Displayed packets only** restricts supported analysis views to the current filtered set. Statistics refresh as live packets are analyzed.

In **I/O graph**, enter one display filter per line and choose **Apply series**. An empty line counts all packets. Intervals are 0.01, 0.1, 1, 10, or 60 seconds. The graph displays packets per interval, retains at most the latest 100,000 intervals, and reports omitted earlier intervals. Choose a longer interval to cover a longer capture.

## Save captures and export results

**File → Save as** saves all durable packets, including packets still awaiting analysis. A filename without an extension gets `.pcapng`. pcapng preserves interface metadata; pcap requires compatible link types.

Use **File → Export specified packets** for pcap or pcapng, or **Export dissections** for analysis data. Choose a target: all analyzed packets, displayed packets, the selected packet, marked packets, the range between the first and last marks, or an explicit numbered range. For ranges, use forms such as `1-10,15,20-`; the final open range runs to the last analyzed packet. **Exclude ignored packets** removes flagged packets from the export.

| Dissection format | Output |
| --- | --- |
| JSON | An array of packets following redhound's packet schema. |
| NDJSON | One packet object per line. |
| Text | The indented protocol tree. |
| CSV | Visible packet-list columns, including custom fields. |

Exports use the chosen analyzed packet set, while ordinary Save includes all durable frames. Outputs are written to a temporary file and replace the destination only after completion. Saving a reconstructed stream is a separate operation in Follow TCP Stream.

## Capture live traffic

Follow the [capture permissions guide](../packaging/README.md) before acquiring traffic on Linux or macOS. Run the desktop or terminal application as your normal user. The separate helper opens the capture device and handles the required privileges.

Choose **Start**, select an interface, and optionally enter a BPF acquisition filter such as `tcp port 443`. Capture options include snap length, buffer size, promiscuous mode, and capture direction. Snap length limits the captured bytes per packet; data beyond that limit cannot be recovered from the capture.

Set packet count, duration, or byte count to stop automatically; zero disables each stop limit. A ring-saving path enables rotating pcapng files. Configure rotation by size or time and a retained file count; after that count is reached, older slots are replaced. A size threshold may be crossed by the packet that triggers rotation, because packets are never split across files.

**Stop** keeps the capture available for inspection and saving. **Restart capture** begins a new capture with the previous options and asks how to handle unsaved data. If analysis is still catching up after acquisition ends, wait for the retained and analyzed counts to converge before exporting analysis-dependent results.

## Change dissectors

Stop acquisition and finish file loading before changing profiles, Decode As rules, or dissectors.

**Analyze → Decode As** selects a protocol for a selector such as `udp.port==8443,dns`. Enter multiple rules separated by semicolons, then choose **Apply**. These rules change how summaries, details, filters, and statistics interpret the original bytes. Remove a rule from the dialog and apply again to return to normal protocol selection.

**Analyze → Dissector plugins** registers Ruby dissector files. Choose **Add**, enter the file path, and confirm trust before its first load. Plugins execute Ruby code with your account's permissions; load only files whose contents you trust. After editing or removing a registered file, choose **Reload plugins** to rebuild the current analysis. Plugin files and trust are kept per profile. The [development guide](development.md#find-the-right-layer) links a working plugin example.

Reanalysis keeps the original bytes, marks, ignored packets, time references, and current selection, then refreshes summaries, details, and filters. Analysis preferences changed during capture or file loading wait until it finishes.

## Profiles and preferences

**Preferences** groups appearance, packet-list behavior, acquisition defaults, analysis limits, and optional name resolution. Choose Japanese or English, system/dark/light/high-contrast themes, and font size in the appearance tab. Language defaults to Japanese when `LANG` begins with `ja`, and English otherwise. Switching language updates the open screen and dialogs. Name resolution is optional and runs asynchronously.

Open **Profiles** from the Edit menu or **Manage profiles** in Preferences. Create a profile for a task, duplicate one to retain its settings, or select its name to switch. The active and default profiles cannot be deleted. Stop capture and finish file loading before switching; the current capture is reanalyzed with the selected profile's configuration.

The default profile lives in the configuration directory; other profiles live under `profiles/NAME`. Each holds `preferences.yml`, `columns.yml`, `coloring_rules.yml`, `filters.yml`, `decode_as.yml`, and `plugins.yml`. Named filters are profile-specific. Recent files, recent filter history, and window geometry are shared.

| Platform | Default configuration directory |
| --- | --- |
| Linux | `$XDG_CONFIG_HOME/vanken`, or `~/.config/vanken` |
| macOS | `~/Library/Application Support/Vanken` |
| Windows | `%APPDATA%/Vanken` |

Configuration uses schema version 1, safe YAML, and atomic saves. Logs rotate and do not retain raw packet bytes. `--debug` enables debug logging when launching Vanken.

## Recover an interrupted capture

After an interrupted capture, the next start offers recovery or discard for owned, inactive session directories. **Recover** rebuilds analysis from the retained raw frames. The recovered capture remains unsaved until you save it. Sessions still used by a running process are excluded. If recovery fails, the raw session remains available for another attempt.

For very large or busy captures, see [performance and limits](performance.md). The documented stream, custom-column, and I/O graph limits above bound their displayed results.

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
| Mark all displayed / clear marks | Ctrl+Shift+M / Ctrl+Alt+M |
| Previous / next packet | Alt+Up / Alt+Down |
| Previous / next in TCP conversation | Ctrl+, / Ctrl+. |
| Go to packet | Ctrl+G |
| Follow TCP Stream | Ctrl+Alt+Shift+T |
| Decode As | Ctrl+Shift+U |
| Reload plugins | Ctrl+Shift+L |
| Quit | Ctrl+Q |

Terminals differ in the keys they transmit. Use the command palette when a shortcut is intercepted by the terminal. Type an action name, then use Up/Down and Enter to run it. Column movement, width, and visibility have controls in the column editor, so they do not require dragging. File operations in the terminal open a path-entry dialog.

```sh
vanken --tui capture.pcapng
vanken --headless --read capture.pcapng --print-columns --filter 'tcp.port == 443'
```

The second command prints tab-separated standard columns for matching packets and exits. `--filter` takes a Vanken display filter. `--no-yjit` disables automatic YJIT activation. Use `vanken --help` for all supported options; add `bundle exec exe/` before the executable name when running from a source checkout.
