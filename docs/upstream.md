# Architecture and dependency contracts

The architecture test keeps redhound references inside Gateway and the helper, and Zaniah references inside UI. Core stores and VDF do not depend on rendering. App::Document coordinates reception, ordered analysis, filter jobs, selection data, and atomic saves.

The receiver writes frames.bin and frames.idx. A separate unprivileged Ruby process reads durable records and performs ordered, stateful analysis once per frame. Private pipes return packed batches of up to 256 frames; the document writes columns, annotations, summaries, and reassembled details before publishing the batch count. Filter changes reevaluate the current batch without repeating stateful analysis. Reception flushes every 256 frames or 50 ms, including idle periods. Final flush and analyzer drain retain the complete tail. UI notifications are limited to ten per second. Detail dissection, row reads, sorting, saving, and scanning run outside UI callbacks.

The disk index uses 32 bytes per frame: `Q<L<L<q<S<S<Cx3` packs offset, captured length, original length, nanosecond timestamp, link type, interface index, direction, and reserved bytes. A separate read handle accesses durable records without retaining a second index in memory or moving the writer. Recovery scans one record at a time. Columns and annotations use compact 32-byte records and intern strings. Summaries and their 8-byte offsets are stored on disk; ordinary details are lazy. Reassembled details preserve the original analysis result. Spool directories use mode 0700, files 0600. Recovery rejects symlinks and incomplete records.

Slow scans use a named ProcessPool handler with JSON-compatible immutable request data and a read-only spool reader. Workers do not run stateful analysis or modify the spool. Cancellation and generation checks stop old jobs from replacing current results.

## redhound 2.0.0.rc2

| Contract | Adapter and checks |
| --- | --- |
| `Redhound.open`, `next_packet(timeout:)`, `stopped?`, `stop`, `close` | FileReader; pcap/pcapng nanosecond round trips |
| `Redhound.dissect`, private registry copy, engine assignment | Dissector; decoding and field catalogs |
| Packet layers, field_values, summary, meta; fields, diagnostics, offsets | PacketView and DetailBuilder; stable IDs, escaped literals, repeated fields |
| `Analysis::Session.new(stats: [], max_state_bytes:, max_flows:)`, update, finish | Analyzer; stream, budget, relative sequence, expert annotations |
| Capture::Interface, writers, Capture::Stats | FileWriter; interface preservation and mixed-link pcap rejection |
| Capture.interfaces, Capture.open, BPF compiler/verifier | Interfaces, LiveCapture, CaptureFilter; privileged integration |

IP reassembly exposes a logical packet through `meta[:reassembled_packet]`. TCP analysis exposes fields and logical protocol details, but no stable complete TCP byte-buffer API is used. Logical fields are labeled reassembled and do not point into unrelated original-frame bytes. Separate reassembled byte tabs await a supported upstream contract.

Helper stdout contains pcapng only; stderr contains versioned JSONL hello, started, stats, warning, error, and stopped events. SIGTERM and parent stdin EOF request orderly termination; signal handlers only change flags. Privileged launch checks root-owned wrappers and ancestors, uses argument arrays, and strips Ruby startup/dependency injection from inherited environment variables.

## Zaniah 0.12

Vanken uses upstream mutable lists, VirtualTable, TreeView, HexView, token completion, validation states, SplitPane, menus/actions, native dialogs, and ProcessPool. No duplicated incubator implementation remains. The upstream ADR and component docs cover resizing, tail following, TUI representation, and accessibility.

Upgrades require contract tests, then the full suite, types, privileged capture, benchmarks, and native smoke. Changes to private packet/session APIs belong inside Gateway.
