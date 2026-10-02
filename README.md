# Vanken

A packet capture and inspection desktop application written in Ruby. Vanken reads pcap and pcapng files, displays a virtual packet list alongside protocol details and bytes, and filters captures with its own display filter language.

Packet acquisition runs in a separate helper; ordered packet analysis runs in another unprivileged process. The desktop application runs as a regular user. Raw frames and summaries are spooled to private files; slow filters use worker processes.

## Requirements

- Ruby 3.3 or newer; Ruby 3.4 or 4.0 with YJIT is recommended.
- Linux with a desktop session, or macOS. File inspection is also available on Windows; live capture uses Linux packet sockets or macOS BPF.
- Linux desktop dependencies: Vulkan loader and drivers, fonts, and `zenity` for native file dialogs. On Ubuntu: `sudo apt install libvulkan1 mesa-vulkan-drivers fonts-dejavu-core fonts-noto-cjk zenity`.

## Install

```sh
gem install vanken
vanken capture.pcapng
```

For a source checkout:

```sh
git clone https://github.com/ydah/vanken.git
cd vanken
bundle install
bundle exec exe/vanken capture.pcapng
```

Strict gem builds require RubyGems 4.0.16 or newer; older versions reject the pinned redhound prerelease with a recommendation warning.

Open a capture from the toolbar, a recent file, or a file drop. Select a packet to inspect its protocol tree and bytes. Selecting a field highlights its bytes; selecting bytes finds the corresponding field. Columns can be sorted, resized, hidden, and reordered. Themes, font size, split positions, columns, and filter history persist between sessions.

Enter a display filter and choose Apply, or press Enter in the filter field:

```text
tcp.port == 443
ip.addr in {192.0.2.0/24, 198.51.100.5}
tcp.flags.syn == true && tcp.flags.ack == false
http.host contains "example"
frame.len > 1000 && !udp
```

Vanken display filters (VDF) and acquisition filters (BPF) are separate languages. See [display filters](docs/filters.md) for operators, types, and repeated fields.

## Analysis

Use the menus or the command palette (Ctrl+Shift+K; Command+Shift+K in the macOS desktop application) to find actions. Search by display filter, hexadecimal bytes, string, or regular expression. Mark and ignore packets, change the time reference, and move between packets in the same conversation. Packet and field context menus expose filter and analysis actions.

Coloring rules can be edited, reordered, imported, and exported. Add a protocol field as a custom column from the details tree, then change its position, width, or visibility in the column editor. Custom columns sort by their field types.

Follow TCP Stream reconstructs each direction, reports missing data, and supports ASCII, hexadecimal, and raw views, searching, saving, and excluding a stream. Statistics include protocol hierarchy, conversations, endpoints, and packet properties. I/O graphs accept display filters per series and intervals from 0.01 to 60 seconds. Expert information links diagnostics to their packets.

Decode As rules and registered Ruby dissector plugins are applied to packet summaries, details, and filter workers. Plugins require an explicit trust confirmation before loading. Save captures as pcap or pcapng, export selected ranges, or export dissections as JSON, NDJSON, text, or CSV.

Preferences include Japanese and English, dark/light/system/high-contrast themes, analysis limits, and optional asynchronous address resolution. Profiles keep preferences, columns, coloring, bookmarks, Decode As rules, and plugins separate; recent files and window geometry are shared. Stop capture before switching profiles or changing dissectors. Analysis preferences changed during loading or capture are applied when it finishes. Interrupted captures can be recovered or discarded on the next start.

## Capture

Choose Start, select an interface, and optionally set a BPF acquisition filter. Stop preserves captured packets for inspection and saving. Vanken asks before discarding an unsaved capture.

Capture options include automatic stopping by packet count, duration, or byte count, and rotating pcapng files by size or time with a bounded file count. The welcome screen shows interface traffic rates. Saving includes all durable packets even while analysis is still catching up.

```sh
bundle exec exe/vanken-capture --list-interfaces
bundle exec exe/vanken-capture --check --interface lo
```

Direct acquisition works when the account already has permission. Privileged launching requires a root-owned installation with a fixed interpreter and dependencies; see [capture helper setup](packaging/README.md). Run the desktop application as a regular user.

The gem includes `vanken-setup-permissions` for administrator installation of Linux capture permissions and the macOS BPF LaunchDaemon. Review the platform-specific setup guide and the command's `--dry-run` output first. GitHub releases also include the permission policies, desktop entry, wrappers, and macOS script in a packaging archive.

## Command line

```sh
bundle exec exe/vanken --headless --read capture.pcap --print-columns --filter 'tcp.port == 443'
bundle exec exe/vanken --tui capture.pcapng
bundle exec exe/vanken --headless --smoke
```

`--no-yjit` disables default YJIT activation. `--debug` enables debug logging. Preferences use safe YAML in the platform's user configuration directory; logs rotate without retaining raw packet bytes.

The terminal UI supports opening captures, selecting packets, applying filters, and starting/stopping capture with keyboard actions. Details of keyboard controls, settings files, and analysis limits are in the [usage guide](docs/usage.md).

## Development

```sh
bundle install
bundle exec rake
bundle exec rake rbs
bundle exec ruby script/generate_fixtures.rb --performance
bundle exec ruby script/benchmark.rb
script/capture-ci.sh
```

To develop with a sibling Zaniah checkout, set `VANKEN_ZANIAH_PATH=../zaniah` when running Bundler. Production dependencies are redhound `2.0.0.rc2` and Zaniah `~> 0.12.4`.

See [upstream contracts](docs/upstream.md), [measured performance](docs/performance.md), and [release procedure](docs/releases.md). Live acquisition can outpace analysis, and redraw latency on slower Linux machines remains above the design target; captured packets are retained while queued analysis finishes.

## License

[MIT](LICENSE.txt).
