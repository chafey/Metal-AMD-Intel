# Tuning for Duo Cards and the Infinity Fabric Link jumper

Guidance on making Metal programs fast on configurations where part of the
working set may live on a remote GPU partition.

## Rules of thumb

1. **Place, then touch.** Allocate a buffer on the partition that will read
   it most. *Supported:* isolated peer pulls run ~27–30 GB/s vs ~67 GB/s
   for local device↔own-VRAM blits — remote reads cost more than half the
   bandwidth ([p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md),
   [copy-paths](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md)).
2. **Stage big transfers, and keep them few.** Prefer explicit bulk copies
   on dedicated queues over letting many flows hit remote buffers at once.
   *Supported with a number:* hive aggregate peaks at ~90 GB/s with ≤4
   concurrent bulk flows and *falls* to ~51–55 GB/s at 8, with unfair
   per-stream shares ([bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md));
   small ops pay a further per-in-flight-op penalty
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
