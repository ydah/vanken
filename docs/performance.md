# Performance measurements

Run the production receiver, analyzer process, display filters, and UI benchmark:

```sh
bundle exec ruby --yjit script/benchmark.rb 1000000 120 4
bundle exec ruby --yjit script/native-smoke.rb
script/capture-ci.sh
```

The benchmark arguments are packet count, UI samples, and slow-filter worker count. Zero workers skips the slow filter. Functional failures raise; JSON reports each numeric performance target separately. For a sibling Zaniah checkout, set `VANKEN_ZANIAH_PATH=../zaniah` when installing and running the bundle.

## Workload and measurement boundaries

The synthetic source yields valid 58-byte Ethernet/IPv4/UDP frames individually, reusing one frozen byte string. Addresses and ports are constant. Receiver timing includes the production disk spool and flushes. Document timing includes reception, ordered stateful analysis in an unprivileged child process, packed IPC batches, catalog updates, and persisted annotations and summaries. The fast filter `udp && udp.port == 54321` matches every frame. The slow filter `ip.ttl == 64` uses four real named `Capture::FilterWorker` processes; timing includes cold worker startup.

Retained heap is the difference in `ObjectSpace.memsize_of_all` after GC, divided by frame count. It excludes reserved heap pages, native allocations, child heaps, and filesystem cache. It is not RSS. Actual RSS comes from `ps -o rss= -p PID`. Document analysis samples parent and analyzer RSS every 250 ms and reports their combined peak increment, subtracting parent RSS before ingest and the first child sample. Child startup after that first sample contributes to the increment. The receiver-only benchmark now runs in a separate process so its allocator pages do not inflate the document baseline. A 50-frame warm-up initializes document caches. After-filter RSS is also reported. Slow-filter worker RSS and filesystem cache are excluded; unavailable RSS is `null`, never a passing result.

The component UI measurement scrolls a production virtual table with one million logical rows and 20 visible rows. It uses the bundled Abel font, a 1200 × 420 viewport, and 20 warm-up frames. This measurement excludes application chrome and packet row IO.

Complete-application measurements use `Application`, `MainView`, real stored packets, system fonts, and a 1280 × 800 viewport. Packet 1 is selected, IPv4 is expanded, and TTL is highlighted in both details and bytes. After 100 warm-up frames, the benchmark measures 120 renders. The growing scenario releases 25,000 additional frames at 5,000 frames/s, follows the packet-list tail, and verifies actual source progress during sampling. Counts are checked after the whole capture drains.

`render(present: false)` includes layout, prepaint, scene paint, glyph shaping, and accessibility updates. Scene timing ends after paint and is reported separately, matching the design's `Inspection.snapshot(window).frame` criterion. Headless measurements exclude pixel rasterization, native events, and GPU presentation. Native smoke reports both scene time and total tick time, including presentation.

## Recorded arm64 results

Measured on 2026-10-02 using Ruby 4.0.6, YJIT, `arm64-darwin25`, and Zaniah 0.12.0. These are individual workstation runs, not isolated-machine medians. A six-second focused test run overlapped the beginning of the full benchmark; its UI phases ran without that competing test job.

| Measurement | Result | Target |
| --- | ---: | ---: |
| Receiver, 1,000,000 frames | 324,609 frames/s | ≥ 100,000 |
| Ingest and analyze, 1,000,000 frames | 15,620 frames/s; 64.0204 s | ≥ 15,000 |
| Fast filter, 1,000,000 matches | 1.5499 s | ≤ 3 s |
| Slow filter, four workers, 1,000,000 matches | 5.2345 s | ≤ 60 s |
| Retained parent heap before/after fast filter | 100.76 / 111.91 B per frame | Heap proxy only |
| Virtual table, render p95 | 15.577 ms | ≤ 33 ms |
| Virtual table during ingestion, render p95 | 13.880 ms | ≤ 33 ms |
| Complete application, scene p95 | 29.186 ms | ≤ 33 ms |
| Complete application during ingestion, scene p95 | 30.373 ms | ≤ 33 ms |
| Complete application during ingestion, total render p95 | 31.479 ms | Reported separately |

All 120 growing-application samples overlapped actual traffic: 13,200 frames were produced in 2.6471 seconds (4,986.62 frames/s), while analyzed rows grew from 512 to 13,568. All 25,256 frames, including the initial 256, completed in 5.0219 seconds without loss.

A separate native 120-sample run produced 17,103 frames in 3.4840 seconds (4,909 frames/s, within the 256-frame pacing tolerance). Durable rows grew from 768 to 17,920 and analyzed rows from 768 to 7,357 during sampling. Scene p95 was 28.862 ms; total native tick p95 was 44.518 ms. The complete 25,000-frame capture drained without loss. This short run demonstrates scene responsiveness, but does not establish sustained backlog limits.

The former in-process analyzer exceeded 33 ms during correctly paced native ingestion. The default analyzer now runs in a separate unprivileged Ruby process, as required by the design's alternative. The child preserves analysis order and state, sends bounded batches through private pipes, and retains no complete second column store. The UI reads cached rows asynchronously.

The first process benchmark measured a parent RSS increment of 189.97 B/frame and a sampled parent-plus-analyzer increment of 196.94 B/frame. Its baseline included pages from the earlier million-frame receiver run. After fast filtering, parent RSS reached 215.47 B/frame, exceeding the 200 B target. IPC now reserves its exact payload size and reuses one read buffer; fast port predicates read packed fields directly instead of allocating full rows, and metadata is fetched only when a filter uses it. A fresh document-only repeat measured 185.38 B/frame in the parent and 197.25 B/frame combined during analysis, but 210.39 B/frame after filtering. Historical results now reserve their known maximum capacity once, avoiding repeated native buffer growth. A final quiet RSS measurement is required before treating the after-filter target as satisfied.

## Linux capture and operation latency

`script/capture-ci.sh` uses an isolated Linux network namespace, a root-owned capture helper, and a UID 1000 UI process. It sends 1,500,000 numbered UDP datagrams at 5,000 frames/s for 300 seconds. The helper uses an incoming packet socket and `udp dst port 54321`; a UDP sink prevents ICMP responses. After shutdown and drain, sent, kernel received, helper captured, durable, and analyzed counts must agree, and dropped, interface-dropped, and freeze counts must all be zero.

JSON evidence includes actual sender rate, UI scene p95 during traffic, and one-second backlog samples. Kernel pending derives from the helper's statistics timestamp. Helper-to-durable compares that sample with a later GUI count and can be negative; it is not an atomic pipe-depth measurement. Final counts are exact. The workflow uploads evidence even on failure.

The same script creates a capture of at least 100 MB, measures the open operation through the render showing its first UDP row, then selects 20 different packets while loading continues. The newly generated file is in the OS page cache; this is not a cold-disk test. Each selection must show both detail and byte panes; the elapsed time ends at the render that produced the verified scene. Subsequent Inspection assertion time is reported separately. Targets are first row ≤ 1 second and every selection ≤ 50 ms. To measure only these operations:

```sh
bundle exec ruby --yjit -Ilib script/capture-performance.rb --ui-only
```

The native and synthetic runs above do not substitute for this five-minute Linux capture test. x86_64 results and the 100 MB operation-latency results must be recorded from their corresponding runs. Varied addresses, large TCP flow sets, reassembly, and plugins are outside the repeated-UDP benchmark's scope.
