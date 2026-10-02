# Performance and limits

## Understand the packet counts

The status bar distinguishes retained packets, analyzed packets, displayed packets, and capture drops. Live acquisition can outpace analysis: packets already retained on disk remain available while the analyzer catches up. Stopping capture stops acquisition; analysis of the retained tail continues.

**Save as** includes all durable packets, even before analysis finishes. Filtered exports, dissection exports, streams, and statistics depend on analyzed packets. Wait for the analyzed count to reach the retained count before exporting a complete analysis result. See [saving and exporting](usage.md#save-captures-and-export-results).

## Keep a large capture manageable

- Use a BPF acquisition filter to avoid retaining unwanted traffic. Display filters change the view after acquisition and do not reduce the captured data.
- Set a packet, duration, or byte stop limit for bounded captures. Ring saving limits the retained rotated files, but does not bound the current session's analysis spool.
- Choose snap length carefully. A shorter value reduces stored packet bytes, but truncates payloads and can prevent complete dissection or stream reconstruction.
- Leave disk space for the session spool and saved or exported captures. Packet data and indexes live on disk; disk-backed storage still consumes memory for analysis, caches, and filter results.
- Watch the **Dropped** count. An increasing count indicates capture loss; retained-packet counts cannot account for packets that never reached Vanken.
- When analysis falls behind, stop acquisition and let it finish. Restricting traffic with a capture filter is more effective than repeatedly changing a slow display filter.

See [live capture options](usage.md#capture-live-traffic) for buffer size, stop limits, and file rotation, and [display filters](filters.md) for progressive filtering.

## Bounded views

Some views intentionally bound their results:

- [Follow TCP Stream](usage.md#follow-a-tcp-stream) previews at most 16 MiB; saving the reconstructed stream includes data beyond the preview.
- [Custom columns](usage.md#arrange-columns-and-add-a-field) display at most 16 values and 4,096 bytes per cell. Inspect the details and bytes for the full packet.
- [I/O graphs](usage.md#inspect-diagnostics-statistics-and-traffic-rates) retain at most 100,000 intervals. Use a longer interval to cover more of the capture.

Reassembled or generated fields may not map to bytes in an original frame. Vanken labels logical fields without highlighting unrelated original bytes.

## Current performance limits

Throughput, redraw and packet-selection latency, and memory targets remain unmet in some measured workloads. Large captures can take time to analyze and can make interaction slower while reception or filtering continues. Performance depends on the machine, protocol mix, enabled analysis, and storage; a successful CI job does not establish a guaranteed capture rate or memory budget.

Developers can reproduce the receiver, analysis, filter, UI, and live-capture checks using the [benchmark instructions](development.md#measure-performance-and-capture-behavior).
