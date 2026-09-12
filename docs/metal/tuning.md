# Tuning for Duo Cards and the Infinity Fabric Link jumper

Guidance on making Metal programs fast on configurations where part of the
working set may live on a remote GPU partition.

## Rules of thumb

1. **Place, then touch.** Allocate a buffer on the partition that will read
   it most. *Supported:* even the best remote route (single kernel pull)
   runs ~113 GB/s with no cache benefit and ~90 under full-duplex load,
   against device-local bandwidth in the hundreds of GB/s; the blit route
   is worse still at ~27–30 GB/s vs ~67–74 GB/s local blits
   ([p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md),
   [copy-paths](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md),
   [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)).
2. **Copy with kernels, not blits — and one flow per link.** Explicit bulk
   copies beat remote paging, but the copy *engine* matters enormously.
   *Supported:* kernel-driven remote pulls reach ~90 GB/s per direction
   on a link and ~330 GB/s hive-wide across four independent links,
   while the blit path plateaus at ~90 GB/s hive-wide under any schedule;
   two concurrent flows sharing one link collapse it to ~46 GB/s
   combined, and a global in-flight cap of 4 beats full concurrency
   (228 vs 185 GB/s).
   [ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).
   Prefer ≥512 MiB per flow (fixed per-op costs eat 15–30% of a 64 MiB
   kernel pull); small ops additionally pay a per-in-flight-op penalty
   ([TP-decode sim](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md)).
3. **One partition per render graph.** Keep all attachments of a render pass
   local to a single partition. *Not yet measured* — the benchmarks here
   cover blit/compute traffic only; treat as unvalidated intuition.

## Topics

- Buffer placement strategies and `MTLHeap` partitioning per device
- Cost model of remote-VRAM paging vs. explicit copies (measure with `if-bench`)
- Cross-device synchronization patterns (see
  [../../examples/swift/if-peer-access](../../examples/swift/if-peer-access))
- Working-set sizing under `recommendedMaxWorkingSetSize` on 2×32 GB cards
