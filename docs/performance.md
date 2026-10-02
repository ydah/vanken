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

The Linux shared runner used Ruby 3.4.10 with YJIT and public Zaniah 0.12.1. [The complete benchmark and 5,000 deterministic fuzz cases](https://github.com/ydah/vanken/actions/runs/36975615332), at Vanken commit `5de8854`, finished without functional errors. These measurements precede the visible-row batching change. Numeric targets are reported separately from job success.

| Measurement | Result | Target |
| --- | ---: | ---: |
| Receiver, 1,000,000 frames | 219,407 frames/s | ≥ 100,000 |
| Ingest and analyze, 1,000,000 frames | 4,849 frames/s; 206.2345 s | ≥ 15,000; missed |
| Parent / combined / after-filter RSS increment | 81.56 / 85.64 / 92.03 B per frame | ≤ 200 |
| Fast / four-worker slow filter | 1.8402 / 21.0254 s | ≤ 3 / 60 s |
| Static full application, total / scene render p95 | 67.705 / 66.455 ms | ≤ 33 ms; missed |
| Growing full application, scene p95 | 67.410 ms | ≤ 33 ms; missed |

The synthetic growing source reached only 312.58 frames/s during sampling, so this run does not demonstrate responsiveness at 5,000 frames/s. An independent [native run](https://github.com/ydah/vanken/actions/runs/36979552426), at commit `8fcce51` after visible-row batching, delivered 4,972.28 frames/s within the pacing allowance. Active scene p95 was 53.057 ms, missing the target; all 25,256 frames completed without loss. Before the focus fix, the corresponding shared-runner scene p95 measurements were 331.801 ms for the growing application and 230.321 ms for native ingestion.

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

Zaniah 0.12.2 avoids rebuilding default style values during merging; 0.12.3 removes a duplicate style merge from element updates. A separate macOS arm64 diagnostic used the actual 256-frame MainView, selected IPv4 TTL, the real text renderer, 40 warm renders, and 20 samples per variant. Applying and reverting each exact implementation changed allocations per render from 71,333 to 67,083 and back, then from 67,083 to 63,918 and back. The combined reduction was 10.4%. Nested element bounds and raw scene commands matched in both directions. Timing varied between runs, so this diagnostic establishes allocation savings, not a stable latency improvement or a passing live-capture target.

## Linux capture and operation latency

`script/capture-ci.sh` uses an isolated Linux network namespace, a root-owned capture helper, and a UID 1000 UI process. It sends 1,500,000 numbered UDP datagrams at 5,000 frames/s for 300 seconds. The helper uses an incoming packet socket and `udp dst port 54321`; a UDP sink prevents ICMP responses. After shutdown and drain, sent, kernel received, helper captured, durable, and analyzed counts must agree, and dropped, interface-dropped, and freeze counts must all be zero.

The live UI follows the production `Application.run` loop: drain foreground work, tick the window, then wait for work when the window is clean. Only actual rendered frames enter latency samples. Document growth is checked between rendered frames during the independently measured sender interval. Forced redraws remain in the component and static-render benchmarks above. A [previous five-minute forced-redraw stress run](https://github.com/ydah/vanken/actions/runs/36977817521), at commit `19b5fe1`, timed out with 1,485,655 kernel drops; it does not establish production-loop capture integrity.

The [first production-loop five-minute run](https://github.com/ydah/vanken/actions/runs/36979552791), at commit `8fcce51`, also failed. The sender delivered 1,500,000 frames at 4,999.9985 frames/s; 722,788 were captured and durable, 777,212 were dropped by the kernel, and 645,120 were analyzed when the 390-second deadline expired. The first file row took 735.646 ms, while the slowest selection took 147.265 ms. These results must not be treated as a passing live-capture or selection-latency gate.

After publishing tail counts together with prepared rows, the [next run](https://github.com/ydah/vanken/actions/runs/36981466284), at commit `a0215b4` with Zaniah 0.12.1, received, captured, and durably stored all 1,500,000 frames at 4,999.9986 frames/s. Kernel drops, interface drops, and freezes were all zero. Analysis reached 974,080 frames when the former 390-second deadline expired, so final analysis equality remained unverified in that run. Full-scene p95 across its 2,070 actual renders was 112.871 ms; this includes post-traffic drain frames and exceeds the 33 ms target. The first file row took 752.545 ms and the slowest selection 134.829 ms.

The integrity check now permits up to 600 seconds of analysis drain after the scheduled traffic duration, fails after 90 seconds without capture, spool, or analysis progress, and records actual post-traffic analysis time. This separates lossless capture verification from slower shared-runner analysis. Sender pacing, exact final count equality, drop checks, and reported numeric performance targets are unchanged; a long drain is not evidence that throughput or responsiveness targets passed.

The [completed integrity run](https://github.com/ydah/vanken/actions/runs/36982911969), at commit `a7f0182`, used Ruby 3.4.11 with YJIT, public Zaniah 0.12.1, and UID/EUID 1000 on the shared x86_64 Linux runner. The sender delivered all 1,500,000 frames over 300.0001 seconds at 4,999.9989 frames/s. Kernel received, helper captured, durable, and final analyzed counts were each exactly 1,500,000; kernel drops, interface drops, and freezes were zero. Analysis completed 301.557 seconds after traffic ended. The maximum sampled analyzer backlog was 864,256 frames. Capture integrity and five-minute sender pacing passed; analysis throughput remains below its target on this runner.

During actual traffic, 2,014 frames rendered and 1,992 showed analyzed-row growth. Scene p95 was 117.226 ms, exceeding 33 ms; total render p95 was 119.103 ms. The same run showed the first row of a 100,000,032-byte file in 641.359 ms, passing the one-second target, but its 20 selections had p95 121.997 ms and maximum 134.433 ms, exceeding 50 ms. A successful workflow therefore confirms functional integrity, not every numeric performance target. Shared-runner analysis and UI latency, together with the macOS after-filter RSS excess above, remain documented constraints for the initial release. Follow-up profiling should first address per-row analysis and layout allocations under the same measured workloads.

JSON evidence includes actual sender rate, UI scene p95 during traffic, and one-second backlog samples. Kernel pending derives from the helper's statistics timestamp. Helper-to-durable compares that sample with a later GUI count and can be negative; it is not an atomic pipe-depth measurement. Final counts are exact. The workflow uploads evidence even on failure.

The same script creates a capture of at least 100 MB, measures the open operation through the render showing its first UDP row, then selects 20 different packets while loading continues. The newly generated file is in the OS page cache; this is not a cold-disk test. Each selection must show both detail and byte panes; the elapsed time ends at the render that produced the verified scene. Subsequent Inspection assertion time is reported separately. Targets are first row ≤ 1 second and every selection ≤ 50 ms. To measure only these operations:

```sh
bundle exec ruby --yjit -Ilib script/capture-performance.rb --ui-only
```

On macOS arm64, Ruby 4.0.6 with YJIT and public Zaniah 0.12.1, a clean 100,000,032-byte capture containing 1,388,889 frames produced its first row in 300.377 ms, with 512 frames analyzed. Twenty different packet selections had p50 20.482 ms, p95 40.513 ms, and maximum 45.276 ms; the first selection took 40.403 ms. Both the first-row and every-selection targets passed in this single run. Pixel rasterization and native presentation were excluded.

The final single-run check with public Zaniah 0.12.3 and the same Ruby, platform, viewport, and clean file workload produced its first row in 287.933 ms, with 256 frames analyzed. Twenty distinct selections had p50 15.728 ms, p95 31.424 ms, and maximum 39.525 ms. Both operation targets passed. The report records the actual installed Zaniah version; this result does not replace the slower shared-Linux-runner measurements above.

Before visible-row batching, the same operation failed its first selection at 105.252 ms. A separate diagnostic reproduced a 107.234 ms background queue wait behind 11 row jobs, while actual detail analysis took 2.677 ms and byte reading 0.129 ms. Nine intermediate renders consumed most of that wait. PacketSource now collects visible-row requests after rendering, fetches them in one background job, and publishes their values in one foreground update. The passing run followed this runtime change; the earlier failure remains part of the evidence.

The native and synthetic runs above do not substitute for this five-minute Linux capture test. Varied addresses, large TCP flow sets, reassembly, and plugins are outside the repeated-UDP benchmark's scope.

## Analysis extensions and cBPF

The address/port optimization uses the public verified capture-filter compiler for eligible complete Ethernet IPv4/IPv6 TCP/UDP packets. It falls back to VDF for unsupported expressions, truncation, fragmentation, extension headers, common UDP tunnels, other link types, Decode As, or plugins. This preserves the fields seen by the dissector.

On 2026-10-02, Ruby 4.0.6 with YJIT on arm64 Darwin compared the same 20,000 complete Ethernet/IPv4/UDP frames and expression `ip.addr == 192.0.2.1 && udp.port == 54321`. Three sequential samples per evaluator all matched 20,000 packets. Median stateless VDF dissection/evaluation took 0.339384 s, and the eligible cBPF path took 0.020937 s: 16.21 times faster. This comparison excludes file IO and worker startup. Run `bundle exec ruby --yjit script/filter-performance.rb 20000` to repeat it.

A separate one-million-packet run of the production document measured 0.5529 s for the existing fast filter, 6.2598 s for the four-worker `ip.ttl == 64` scan, and 2.7721 s for the four-worker address/port cBPF scan. Each matched all one million packets. Analysis took 115.6605 s (8,646 packets/s), with 67.2 B/frame retained parent heap before filtering and 81.08 B/frame after the worker scan. This run overlapped integration and UI tests and is not an isolated comparison with the earlier analysis-throughput result. RSS sampling was unavailable and is recorded as null; these heap figures do not establish the RSS target.

The I/O graph check seeds actual frame metadata, packed columns, and annotations for 200,000 TCP frames, then times two series at each supported interval. It excludes packet parsing. The observed interval rebuilds took 0.30–0.33 s, each below the one-second target, with every packet counted in both series. Run `bundle exec ruby --yjit script/analysis-performance.rb` to repeat it. Nightly validation retains the one-million-packet benchmark, evaluator comparison, graph timings, and fuzz results as workflow artifacts.

## Release 0.2 and 0.3 verification with public Zaniah 0.12.4

The [final nightly run](https://github.com/ydah/vanken/actions/runs/36999466662) tested commit `6d05e2a` with Ruby 3.4.10, YJIT, public redhound 2.0.0.rc2, and public Zaniah 0.12.4 on the shared x86_64 Linux runner. The receiver, complete one-million-packet analysis, all filters, graph accounting, and 5,000 deterministic fuzz cases passed their functional checks. Commit `2169b6a` adds the administrator installer and packaging without changing this analysis or rendering code.

| Measurement | Result | Target |
| --- | ---: | ---: |
| Receiver, 1,000,000 frames | 181,777 frames/s | ≥ 100,000 |
| Ingest and analyze, 1,000,000 frames | 4,073 frames/s; 245.5186 s | ≥ 15,000; missed |
| Parent / combined / after-filter RSS increment | 80.26 / 87.48 / 91.06 B per frame | ≤ 200 |
| Fast / four-worker slow filter | 1.9499 / 22.9614 s | ≤ 3 / 60 s |
| Four-worker address/port cBPF filter | 7.1322 s; 1,000,000 matches | Reported separately |
| Static full application, total / scene render p95 | 73.154 / 71.903 ms | Scene ≤ 33 ms; missed |
| Growing full application, total / scene render p95 | 44.370 / 42.490 ms | Scene ≤ 33 ms; missed |

The growing full-application source produced only 427.6 frames/s during sampling, so that measurement does not establish responsiveness at 5,000 frames/s. The isolated virtual-table ingestion measurement similarly does not replace the complete application or live capture. Job success does not mean all numeric targets passed.

The same nightly run compared VDF and cBPF over the same 20,000 packets, with three samples per evaluator. Median times were 1.239493 s and 0.055858 s respectively, a 22.19-fold improvement, with identical match counts. Two-series I/O graph rebuilds for 200,000 frames took 1.024516, 1.011629, 1.005382, 0.996721, and 0.996433 s at intervals 0.01, 0.1, 1, 10, and 60 s. The three shortest intervals narrowly exceeded the one-second target.

On the Mac with Ruby 4.0.6, YJIT, and public Zaniah 0.12.4, the final 100,000,032-byte file check displayed its first verified row in 645.209 ms. Twenty distinct selections had p50 26.660 ms, p95 35.778 ms, and maximum 51.223 ms. The first-row target passed; the every-selection 50 ms target failed on the first selection. These are single-run headless production-window measurements with the same exclusions described above.

A native Mac run with 120 samples verified opening, selection, filtering, and all 25,256 captured frames. Scene p95 was 28.804 ms and total native tick p95 was 47.850 ms. During sampling, the source delivered 19,453 frames in 4.40697 s, or 4,414.14 frames/s. The scene result meets 33 ms at that observed rate, but does not establish the requested 5,000 frames/s target.

The [final five-minute Linux capture run](https://github.com/ydah/vanken/actions/runs/36999897569), at `2169b6a`, used Ruby 3.4.11 with YJIT and the public dependencies above. The actual administrator command installed 74 root-owned files, and capture-boundary tests verified the installation before running the UI with UID/EUID 1000. A real PTY additionally passed file opening, packet selection, filtering, the command palette, capture options, actual capture start/stop, and quit.

The independent sender delivered 1,500,000 frames over 300.000066 s at 4,999.9989 frames/s. Kernel received, helper captured, durable, and final analyzed counts all equaled 1,500,000; drops, interface drops, and freezes were zero. Analysis drained 208.956 s after traffic ended, with a maximum sampled backlog of 578,656 frames. This establishes capture integrity and sender pacing while retaining the analysis-throughput limitation.

During actual traffic, 2,492 frames rendered and 2,395 showed analyzed-row growth. Scene p95 was 78.807 ms and total render p95 was 81.711 ms, exceeding the 33 ms scene target. The file check in the same run displayed its first row in 788.282 ms, passing one second; selection p95 was 104.404 ms and maximum 111.676 ms, exceeding 50 ms. The earlier measurements remain above for comparison; shared-runner results do not establish a controlled before/after speedup.

### Same-host analysis regression comparison

The old Linux analysis time of 206.2345 s and the latest 245.5186 s came from different shared VMs. A separate same-host comparison checks the release procedure's 15% regression threshold without treating those environments as identical.

The initial `26b3e7b` source and current `2169b6a` source were archived and run alternately on the same Mac. Both used the current public dependency lockfile, Ruby 4.0.6 with YJIT, a fresh Ruby process and analyzer child, the identical 58-byte UDP fixture and Enumerator, and a 50-frame warm-up. Each timed `Document.ingest(...).wait` with `process_analysis: true` over 100,000 frames. Initialization, warm-up, cleanup, kernel acquisition, and UI were excluded; no other local tests ran concurrently.

| Sample | Initial source, seconds | Current source, seconds |
| --- | ---: | ---: |
| 1 | 11.307215 | 11.508561 |
| 2 | 11.623641 | 12.657844 |
| 3 | 12.123842 | 12.085011 |
| Median | 11.623641 | 12.085011 |

Median elapsed time increased 3.97%; median throughput changed from 8,603.16 to 8,274.71 frames/s, a 3.82% decrease. The 15% threshold was not exceeded for this workload. All six runs verified exactly 100,000 durable and analyzed frames, UDP decoding, no document error, and analyzer-child cleanup. This comparison does not explain the separate shared-VM Linux timing difference or establish the 15,000 frames/s target.
