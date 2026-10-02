# Changelog

## 0.2.0

- Add editable packet coloring, four search modes, marks, ignored packets, time references, and conversation navigation.
- Add Follow TCP Stream with retransmission handling, missing-data indicators, searching, saving, and stream exclusion.
- Add protocol hierarchy, conversations, endpoints, expert information, capture properties, and filtered I/O graphs.
- Add typed custom columns, Decode As rules, trusted Ruby dissector plugins, packet-range exports, and JSON, NDJSON, text, and CSV exports.
- Add the command palette, profile-based preferences, Japanese and English screens, high-contrast themes, and keyboard operation in the terminal UI.
- Add automatic capture stopping, rotating pcapng files, interface traffic graphs, optional asynchronous address resolution, and interrupted-capture recovery.
- Accelerate supported address and port display filters while preserving ordinary evaluation for other packets and dissector extensions.
- Preserve captured packets awaiting analysis when saving, and retain filter results and current selection through reanalysis.

Live acquisition can outpace analysis on slower systems. Captured packets remain available while queued analysis finishes; redraw latency on measured Linux systems remains above the design target. See [measured performance](https://github.com/ydah/vanken/blob/main/docs/performance.md).

Requires Ruby 3.3 or newer. Live capture supports Linux and macOS; Windows supports file inspection. See [capture permissions](https://github.com/ydah/vanken/blob/main/packaging/README.md).

## 0.1.0

Initial release.
