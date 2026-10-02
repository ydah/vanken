# Vanken

A packet capture and inspection desktop application written in Ruby. Vanken reads pcap and pcapng files, displays a virtual packet list alongside protocol details and bytes, and filters captures with its own display filter language.

Packet acquisition runs in a separate helper; ordered packet analysis runs in another unprivileged process. The desktop application runs as a regular user. Raw frames and summaries are spooled to private files; slow filters use worker processes.

## Requirements

- Ruby 3.3 or newer; Ruby 3.4 or 4.0 with YJIT is recommended.
- Linux with a desktop session, or macOS. File inspection is also available on Windows; live capture uses Linux packet sockets or macOS BPF.
- Linux desktop dependencies: Vulkan loader and drivers, fonts, and `zenity` for native file dialogs. On Ubuntu: `sudo apt install libvulkan1 mesa-vulkan-drivers fonts-dejavu-core fonts-noto-cjk zenity`.

## Run from source

```sh
git clone https://github.com/ydah/vanken.git
cd vanken
bundle install
bundle exec exe/vanken capture.pcapng
```

Initial RubyGems publication is pending. To install a locally built gem:

```sh
gem build --strict vanken.gemspec
gem install ./vanken-0.1.0.gem
vanken capture.pcapng
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

## Capture

Choose Start, select an interface, and optionally set a BPF acquisition filter. Stop preserves captured packets for inspection and saving. Vanken asks before discarding an unsaved capture.

```sh
bundle exec exe/vanken-capture --list-interfaces
bundle exec exe/vanken-capture --check --interface lo
```

Direct acquisition works when the account already has permission. Privileged launching requires a root-owned installation with a fixed interpreter and dependencies; see [capture helper setup](packaging/README.md). Run the desktop application as a regular user.

## Command line

```sh
bundle exec exe/vanken --headless --read capture.pcap --print-columns --filter 'tcp.port == 443'
bundle exec exe/vanken --tui capture.pcapng
bundle exec exe/vanken --headless --smoke
```

`--no-yjit` disables default YJIT activation. `--debug` enables debug logging. Preferences use safe YAML in the platform's user configuration directory; logs rotate without retaining raw packet bytes.

## Development

```sh
bundle install
bundle exec rake
bundle exec rake rbs
bundle exec ruby script/generate_fixtures.rb --performance
bundle exec ruby script/benchmark.rb
script/capture-ci.sh
```

To develop with a sibling Zaniah checkout, set `VANKEN_ZANIAH_PATH=../zaniah` when running Bundler. Production dependencies are redhound `2.0.0.rc2` and Zaniah `~> 0.12.3`, including fixes for growing memory use and repeated style allocations during redraws.

See [upstream contracts](docs/upstream.md), [measured performance](docs/performance.md), and [release procedure](docs/releases.md). Version 0.1 implements the file inspection, acquisition, and display filter milestones. Statistics, stream following, coloring, profiles, and later extensions are scheduled for subsequent releases.

## License

[MIT](LICENSE.txt).
