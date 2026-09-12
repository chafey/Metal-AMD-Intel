# Metal Gotchas on MPX / Intel Hosts

A running log of driver, IOAccelerator, and OS-level surprises. Each entry:
symptom, affected configuration, workaround, and OS/driver version observed.

## Template for new entries

```md
### <short title>
- **Affects:** <card(s)>, macOS x.y, IOAccelerator kext version
- **Symptom:** what you see
- **Repro:** minimal case or tool invocation
- **Workaround:** what works
- **Status:** workaround-only / fixed in x.y / filed with Apple
```

## Known issues

### ⚠️ Misaligned vector loads of remote buffer views return STALE data at fake speed
- **Affects:** 2× W6800X Duo peer group, macOS 26.6.2, AMDRadeonX6000 7.0.1 —
  compute loads through `newRemoteBufferViewForDevice:` buffers
- **Symptom:** loads of a 16-byte **but 4-byte-aligned** vector type
  (`uchar4`) from a remote view are served from a non-snooped cache:
  they return data from an initial freshness window plus stale junk
  beyond it, at local-cache speeds (~111–113 GB/s instead of the true
  ~27 GB/s), and **the stale data does not update even after the
  producer GPU rewrites the source and its command buffer completes**.
  Reads of naturally aligned types (`uint`, `ulong`, `float`, `uint4`,
  `ulong2`, `float4`) are coherent at every size and rewrite round
  tested. `blit` copies are always correct. Repeated reads of an
  unchanged source measured at true speed with aligned loads (up to
  1 GiB), so always rewriting the source between timed iterations (as
  `remote-view-check` does) remains the safe benchmarking discipline —
  and **verify contents**, since a bandwidth test that never checks
  data cannot see this bug (this is how a bogus
  "113 GB/s kernel path / 330 GB/s aggregate" claim survived a whole
  benchmark report before `remote-view-check` caught it).
- **Repro:** `tools/.build/release/remote-view-check` — the
  `uchar4 16B*` row is an intentional failure (stale mid/tail at
  111–113 GB/s); all aligned widths print 0 bad at 22–29 GB/s.
  Raw: `docs/benchmarks/raw/2026-09-12-remote-view-check.txt`
- **Workaround:** in any kernel touching a remote view, use naturally
  aligned element types (or 4-byte scalars); keep `remote-view-check`
  green; prefer blit copies for bulk transfers. Also avoid grid-stride
  remote-copy loops in general (`threadgroups_per_grid` is a threadgroup
  *count*, not a thread count — using it as the loop stride is a
  classic 256× slowdown trap).
- **Status:** workaround-only; freshness-window size is unpredictable
  (whole 16 MiB buffers stayed fresh; a 32 KiB tensor was fresh only for
  its first vector; 1 GiB buffers went stale past the first 1 MiB)

### Host writes to `MTLStorageModePrivate` buffer contents stalls submissions
- **Affects:** W6800X Duo, macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** `buffer.contents().copyMemory(...)` on a private-storage
  buffer appears to succeed, but the next command-buffer completion hangs
  indefinitely (`waitUntilCompleted` never returns); the GPUs survive
  process kill
- **Repro:** create a `.storageModePrivate` buffer, write through
  `contents()`, blit it, `waitUntilCompleted()`
- **Workaround:** use `.storageModeShared` (host-visible) buffers for
  anything the CPU initializes or reads back (that is what `if-bench` does)
- **Status:** workaround-only

### `options:` parameter takes shifted storage modes, not `MTLStorageMode*`
- **Affects:** all AMD MPX parts, macOS 26.6.2 (driver assertion text is
  driver-side); same API contract on all macOS
- **Symptom:** `[device newBufferWithLength:options:MTLStorageModePrivate]`
  aborts with `failed assertion 'Invalid cacheMode 2'`
- **Repro:** mtl-bench history — passing the unshifted enum as resource
  options; Swift's `.storageModePrivate` is already shifted, which is why
  Swift code does not trip it
- **Workaround:** `MTLResourceStorageModePrivate`, i.e. `(MTLResourceOptions)
  MTLStorageModePrivate << MTLResourceStorageModeShift`
- **Status:** workaround-only (API misuse, but the failure mode is an opaque
  driver assert rather than a validation error)

### Accumulated uncommitted command buffers stall command-buffer allocation
- **Affects:** W6800X Duo, macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** creating command buffers without ever committing them leaks
  (ARC off, autorelease pool drained late, or driver-side retention) and
  `[queue commandBuffer]` eventually blocks forever; observed within a
  20 000-buffer loop when buffers were not released, and — less reliably —
  in a non-optimized (`-O0`) build of an otherwise-identical ARC loop
- **Repro:** compile a loop of `[queue commandBuffer]` without `-fobjc-arc`
  (or with a late autorelease pool); completes with ARC + `-O2`
- **Workaround:** release or commit each command buffer; keep benchmarks
  optimized (`CMAKE_BUILD_TYPE=Release`, now the default in
  `tools/mtl-bench/CMakeLists.txt`)
- **Status:** workaround-only; root cause (driver retention vs pool timing)
  not established

### IOSurface staging route across the xGMI hive boundary collapses
- **Affects:** W6800X Duo (xGMI hive of 4) + RX 6900 XT (plain PCIe),
  macOS 26.6.2, IOAcceleratorFamily2 487.4.3 / AMDRadeonX6000 7.0.1
- **Symptom:** cross-device IOSurface staging transfers between an
  xGMI-hive GPU and a non-hive GPU reach only 1.3–4.0 GB/s end-to-end
  (vs 8.3–10.2 GB/s between hive members) even though each single hop
  measures normally in isolation; direction-asymmetric (to the non-hive
  card is slower) and dependent-chain latency is unstable (296–4 999
  µs/hop vs ~121–148 µs/hop within the hive). Switching the hop
  implementation to a compute kernel (`--peer-path kernel`) does not
  improve it — the penalty sits at the hive boundary, not the hop engine
- **Repro:** `swift run --package-path tools if-bench -- --device-a <hive-die>
  --device-b <non-hive-gpu> --mode peer --peer-path blit --json` (the
  staging route must be named explicitly; the tool default is `p2p`;
  supporting 2026-09-11 raw captures measured on a hive + non-hive pair
  were removed from `docs/benchmarks/raw/` and are recoverable from git
  history)
- **Workaround:** keep IOSurface-based cross-device sharing inside one
  xGMI hive; for hive↔non-hive movement budget PCIe-class bandwidth and
  batch heavily, or stage via host memory explicitly
- **Status:** observed, mechanism not established (staging page placement
  is not observable via the API)

### Remote buffer views are read-only: using one as a blit destination aborts
- **Affects:** W6800X Duo (all four dies), macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** copying *into* an `MTLBuffer` returned by
  `newRemoteBufferViewForDevice:` kills the process inside the driver with
  `RemoteView supports read-only operation and cannot be used as
  Destination!` (AMDRadeonX6000MTLDriver assert); the GPUs survive the abort
- **Repro:** obtain a remote view (`buffer.perform(Selector(("
  newRemoteBufferViewForDevice:")), with: peerDevice)`), then use it as the
  destination of any blit `copyFromBuffer:...destinationBuffer:...`
- **Workaround:** destination-side pull only — the *reading* device's own
  queue copies from its view into its own VRAM (the direction toshllm's
  `ggml_metal_cpy_xdev_peer()` uses). `if-bench --peer-path p2p` implements
  this pattern behind a changing-pattern coherence gate
- **Status:** workaround-only (assert is driver-side, not a validation
  error; there is no API to query the read-only property)

### Metal peer groups map exactly onto the xGMI hive (cross-hive P2P unavailable)
- **Affects:** W6800X Duo (xGMI hive of 4) + RX 6900 XT (plain PCIe),
  macOS 26.6.2, AMDRadeonX6000 7.0.1 / IOAcceleratorFamily2 487.4.3
- **Symptom:** all four Duo dies report the same non-zero `peerGroupID`
  (`0x4cf5577a51a24576` on the observed machine); the non-hive card reports
  0 and `newRemoteBufferViewForDevice:` returns nil across the hive
  boundary — peer-group P2P is simply unavailable between an MPX hive and
  any non-hive GPU, no error path to catch
- **Repro:** print `device.peerGroupID` for every `MTLDevice` (shown by
  `if-bench` device table as `group=0x…`), or
  `if-bench --device-a <hive-die> --device-b <non-hive> --mode peer
  --peer-path p2p` (notes the skip, emits no rows)
- **Workaround:** treat `peerGroupID != 0 && A.peerGroupID == B.peerGroupID`
  as the P2P gate; cross-hive sharing must stay on the staging/host route
  (see the hive-boundary entry above for its numbers)
- **Status:** by-design limitation as observed; mechanism (why hive members
  share one group id) inferred from IORegistry hive captures, not documented
  by Apple

### Concurrent remote-view pulls are penalised; serialised pulls win
- **Affects:** W6800X Duo (xGMI hive of 4), macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** when every hive member performs remote-view pulls at the
  same time, each in-flight remote op costs ~100–340 µs instead of the
  ~56 µs an isolated pull pays: 12 concurrent 4 KiB pulls take 4.0 ms
  while the same 12 ops done one at a time take 0.54 ms (~7×). A
  llama.cpp/toshllm-style TP-4 all-reduce (every rank pulls every peer,
  `ggml_metal_cpy_xdev_peer()` pattern) therefore costs ~3.1 ms per
  all-reduce; serialising the pull phase across ranks with
  `MTLSharedEvent` chains costs ~0.75 ms — and the cost is flat from
  8 KiB to 64 KiB payloads (fixed-cost, not bandwidth)
- **Repro:** `tools/.build/release/pull-contention --json` (all-to-all
  concurrent vs sequential cases) or
  `tools/.build/release/tp-sim --layers 4 --tokens 3` (event vs chain);
  numbers in
  [the TP-decode report](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md)
- **Workaround:** schedule the pull phase sequentially across ranks
  (event chain rank r → r+1); minimise the *number* of remote ops per
  token (fewer/larger reduces, token batching, TP=2 per Duo module +
  pipeline parallelism across modules) rather than trying to overlap them
- **Status:** observed and quantified; mechanism (driver-side serialisation
  vs hive-level arbiter) not established

### Four consumers of one remote buffer hard-hang the driver
- **Affects:** W6800X Duo (xGMI hive of 4), macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** with N ≥ 4 GPUs concurrently blit-pulling remote views of
  the *same* source buffer, completion never arrives — the waiting
  process wedges indefinitely (not slow: hung; 100 s+ for work that
  serially takes ms). Three concurrent readers are fine; pairwise
  exchange (two consumers, two sources) is fine
- **Repro:** `tools/.build/release/pull-contention --allow-fanin`
  (deliberately gated behind that flag — it wedges until the process is
  killed); the GPUs recover from the kill without a reboot
- **Workaround:** never let the whole hive read one buffer simultaneously
  — shard the source across consumers, or serialise readers with events
  (the tp-sim `chain` schedule structurally avoids ≥4-reader fan-in)
- **Status:** observed; file-worthy (looks like a driver deadlock in
  remote-page-table handling), not yet filed

### Concurrent flows are arbitrated unfairly (blit path; no partition stalls)
- **Affects:** 2× W6800X Duo xGMI hive of 4, macOS 26.6.2,
  AMDRadeonX6000 7.0.1 — blit (`MTLBlitCommandEncoder`) copies
- **Symptom:** this is *not* a stall — both partitions keep making progress,
  but the blit path is capped at ~90 GB/s hive-wide, and above 4
  simultaneous bulk flows aggregate throughput *falls* (~90 → ~51–55 GB/s
  at 8) with per-stream shares unfair (up to 3× spread) and swapping
  winners run-to-run. Scheduling is driver-side, not link-topology-driven.
  Corrected kernel reads (aligned loads) do not dodge anything either —
  they hit the same per-flow rates; the plateau story is "~24–29 GB/s
  per flow, additive across disjoint pairs, arbitrates unfairly above 4
  flows" (see [ceiling report
  v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)).
  Both engines share one rule: **two concurrent flows on the same link
  collapse below a single flow's rate** — serialise per-link egress in
  the application.
- **Repro:** `tools/.build/release/a2a-bw` (phases B3 vs C are the
  concurrency-matched comparison; `--engine kernel` for the fabric path)
- **Workaround:** kernel copies for bulk IF traffic; keep ≤1 in-flight
  flow per link (global cap of 4 already beats full concurrency)
- **Status:** measured and reproduced; root cause (driver work scheduler
  vs remote-page-table arbitration) not isolated

> Each entry must be reproducible with a checked-in tool or example.
