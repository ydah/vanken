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

Measured on 2026-10-02 using Ruby 4.0.6, YJIT, `arm64-darwin25`, and Zaniah 0.12.0. These are individual workstation runs, not isolated-machine medians. Receiver, analysis, memory, and fast-filter figures below come from fresh processes after removing the duplicate in-memory frame index. Slow-filter and UI figures come from the earlier complete benchmark; a six-second focused test overlapped the start of that run, but not its UI phases.

| Measurement | Result | Target |
| --- | ---: | ---: |
| Receiver, 1,000,000 frames | 380,823 frames/s | ≥ 100,000 |
| Ingest and analyze, 1,000,000 frames | 17,012 frames/s; 58.7827 s | ≥ 15,000 |
| Fast filter, 1,000,000 matches | 0.5473 s | ≤ 3 s |
| Slow filter, four workers, 1,000,000 matches | 5.2345 s | ≤ 60 s |
| Retained parent heap before/after fast filter | 67.22 / 75.23 B per frame | Heap proxy only |
| Parent RSS increment after analysis | 183.68 B per frame | ≤ 200 |
| Sampled parent-plus-analyzer RSS increment | 186.27 B per frame | ≤ 200 |
| Parent RSS increment after fast filtering | 209.88 B per frame | ≤ 200; exceeded |
| Virtual table, render p95 | 15.577 ms | ≤ 33 ms |
| Virtual table during ingestion, render p95 | 13.880 ms | ≤ 33 ms |
| Complete application, scene p95 | 29.186 ms | ≤ 33 ms |
| Complete application during ingestion, scene p95 | 30.373 ms | ≤ 33 ms |
| Complete application during ingestion, total render p95 | 31.479 ms | Reported separately |

All 120 growing-application samples overlapped actual traffic: 13,200 frames were produced in 2.6471 seconds (4,986.62 frames/s), while analyzed rows grew from 512 to 13,568. All 25,256 frames, including the initial 256, completed in 5.0219 seconds without loss.

A separate native 120-sample run produced 17,103 frames in 3.4840 seconds (4,909 frames/s, within the 256-frame pacing tolerance). Durable rows grew from 768 to 17,920 and analyzed rows from 768 to 7,357 during sampling. Scene p95 was 28.862 ms; total native tick p95 was 44.518 ms. The complete 25,000-frame capture drained without loss. This short run demonstrates scene responsiveness, but does not establish sustained backlog limits.

The former in-process analyzer exceeded 33 ms during correctly paced native ingestion. The default analyzer now runs in a separate unprivileged Ruby process, as required by the design's alternative. The child preserves analysis order and state, sends bounded batches through private pipes, and retains no complete second column store. The UI reads cached rows asynchronously.

The fresh parent RSS baseline was 48,922,624 bytes, rising to 232,603,648 bytes after analysis and 258,801,664 after filtering. Frame metadata now stays on disk, removing approximately 33.55 MB of retained heap for one million frames. IPC reserves its exact payload size and reuses one read buffer; fast port predicates read packed fields directly, and metadata is fetched only when a filter uses it. Historical filter results reserve their known maximum array capacity once. The filter added 8.01 MB of retained heap but 26.20 MB of RSS; GC pages and JIT code explain only part of the difference. The additional after-filter RSS target remains exceeded on this macOS run.

## Recorded x86_64 results

The Linux shared runner used Ruby 3.4.10 with YJIT and Zaniah 0.12.0. [The complete benchmark and 5,000 deterministic fuzz cases](https://github.com/ydah/vanken/actions/runs/36966042551) finished without functional errors. Numeric targets are reported separately from job success.

| Measurement | Result | Target |
| --- | ---: | ---: |
| Receiver, 1,000,000 frames | 209,288 frames/s | ≥ 100,000 |
| Ingest and analyze, 1,000,000 frames | 4,394 frames/s; 227.6002 s | ≥ 15,000; missed |
| Parent / combined / after-filter RSS increment | 80.53 / 86.76 / 91.04 B per frame | ≤ 200 |
| Fast / four-worker slow filter | 1.9022 / 21.8657 s | ≤ 3 / 60 s |
| Static full application, total render p95 | 357.855 ms | ≤ 33 ms; missed |
| Growing full application, scene p95 | 331.801 ms | ≤ 33 ms; missed |

The synthetic growing source reached only 187.96 frames/s during sampling, so this run does not demonstrate responsiveness at 5,000 frames/s. An independent native run did deliver 4,963.99 frames/s within the pacing allowance, but active scene p95 was 230.321 ms, also missing the target.

Investigation reproduced a Zaniah focus-tree retention bug: a three-row tree retained 18 row handles after six renders. The fix included in Zaniah 0.12.1 releases render-created parent links between frames while preserving manual hierarchies. The same Linux arm64 container, Ruby 3.4.11 with YJIT, UID 1000, fonts, 4,096-packet document, 100 warm renders, and 120 scrolling samples were measured before and after changing only the Dispatcher implementation:

| Measurement | Before fix | After fix |
| --- | ---: | ---: |
| Total render p95 | 170.473 ms | 23.626 ms |
| Scene p95 | 170.023 ms | 22.585 ms |
| Maximum total render | 207.739 ms | 26.533 ms |
| GC p95 | 148.697 ms | 6.289 ms |
| Major GC during 120 samples | 15 | 0 |
| Samples exceeding 33 ms | 43 | 0 |

Per-frame allocations remained approximately 84,600 objects, supporting retained old rows as the cause of expensive GC. The three-row reproduction now retained exactly three current handles after each render, with no obsolete handles. This static arm64 diagnostic establishes the fix's effect; it does not substitute for x86_64 or sustained live-capture verification.

## Linux capture and operation latency

`script/capture-ci.sh` uses an isolated Linux network namespace, a root-owned capture helper, and a UID 1000 UI process. It sends 1,500,000 numbered UDP datagrams at 5,000 frames/s for 300 seconds. The helper uses an incoming packet socket and `udp dst port 54321`; a UDP sink prevents ICMP responses. After shutdown and drain, sent, kernel received, helper captured, durable, and analyzed counts must agree, and dropped, interface-dropped, and freeze counts must all be zero.

JSON evidence includes actual sender rate, UI scene p95 during traffic, and one-second backlog samples. Kernel pending derives from the helper's statistics timestamp. Helper-to-durable compares that sample with a later GUI count and can be negative; it is not an atomic pipe-depth measurement. Final counts are exact. The workflow uploads evidence even on failure.

The same script creates a capture of at least 100 MB, measures the open operation through the render showing its first UDP row, then selects 20 different packets while loading continues. The newly generated file is in the OS page cache; this is not a cold-disk test. Each selection must show both detail and byte panes; the elapsed time ends at the render that produced the verified scene. Subsequent Inspection assertion time is reported separately. Targets are first row ≤ 1 second and every selection ≤ 50 ms. To measure only these operations:

```sh
bundle exec ruby --yjit -Ilib script/capture-performance.rb --ui-only
```

The native and synthetic runs above do not substitute for this five-minute Linux capture test. x86_64 results and the 100 MB operation-latency results must be recorded from their corresponding runs. Varied addresses, large TCP flow sets, reassembly, and plugins are outside the repeated-UDP benchmark's scope.
