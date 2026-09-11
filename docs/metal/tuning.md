# Tuning for Duo Cards and the Infinity Fabric Link jumper

Guidance on making Metal programs fast on configurations where part of the
working set may live on a remote GPU partition.

## Rules of thumb (to be validated)

1. **Place, then touch.** Allocate a buffer on the partition that will read it
   most; let `if-bench`-style measurements confirm the cost of remote access
   before restructuring code around it.
2. **Stage big transfers.** For cross-partition data flow, chunked copies on
   dedicated command queues overlap better than relying on remote paging.
3. **One partition per render graph.** Keep all attachments of a render pass
   local to a single partition.

TODO: replace each rule with measured evidence and links into
[../benchmarks/](../benchmarks/); delete rules the data doesn't support.

## Topics

- Buffer placement strategies and `MTLHeap` partitioning per device
- Cost model of remote-VRAM paging vs. explicit copies (measure with `if-bench`)
- Cross-device synchronization patterns (see
  [../../examples/swift/if-peer-access](../../examples/swift/if-peer-access))
- Working-set sizing under `recommendedMaxWorkingSetSize` on 2×32 GB cards
