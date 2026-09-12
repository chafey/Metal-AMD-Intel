# Tuning for Duo Cards and the Infinity Fabric Link jumper

Guidance on making Metal programs fast on configurations where part of the
working set may live on a remote GPU partition.

## Rules of thumb

1. **Place, then touch.** Allocate a buffer on the partition that will read
   it most. *Supported:* every remote route runs ~24–29 GB/s per flow
   (blit ~24–38, aligned kernel loads ~27–29) against device-local
   bandwidth in the hundreds of GB/s (local blits ~67–74), so remote
   traffic is an order of magnitude off local even in the best case
   ([p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md),
   [copy-paths](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md),
   [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)).
2. **One flow per link; kernels optional.** Explicit bulk copies beat
   remote paging. Kernel-driven pulls are *not* faster than blit — the
   corrected measurements put both at the same per-flow rate; choose
   kernel pulls only when you need to fuse the copy into real work, and
   then load remote views with **naturally aligned types only** (a
   misaligned 16-byte type like `uchar4` silently returns stale data —
   see [gotchas](gotchas.md) and validate with
   [`remote-view-check`](../../tools/remote-view-check/)).
   *Supported:* disjoint GPU pairs scale additively (one pair alone
   ~46–48 GB/s full-duplex; two disjoint pairs ~93–96 combined), but two
   concurrent flows sharing one link collapse below a single flow's rate
   (8 cross streams: 50.8 blit / 73.6–85.1 kernel vs ~93 at one
   flow/link), and ≥5 simultaneous consumers get unstable shares.
   [ceiling report v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).
   Small ops additionally pay a per-in-flight-op penalty
   ([TP-decode sim](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md)),
   and serialized kernel pulls a further ~100 µs/op over serialized blit
   pulls (floors ~160–180 µs vs ~57–65 µs; [p2p matrix latency
   follow-up](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md#follow-up-2026-09-12-kernel-pull-vs-blit-pull-latency))
   — one more reason kernel pulls earn their keep only when fused with
   compute inside the same command buffer.
3. **One partition per render graph.** Keep all attachments of a render pass
   local to a single partition. *Not yet measured* — the benchmarks here
   cover blit/compute traffic only; treat as unvalidated intuition.
4. **Count remote ops, not bytes, when choosing an all-reduce
   schedule.** Bandwidth-optimal multi-GPU schedules that trade bytes for
   op count (NCCL-style 2-shot reduce-scatter + all-gather, double binary
   tree) are **losses** on this driver: `tp-sim --allreduce twoshot` moves
   half the bytes of the naive llama.cpp pull schedule but measures ~5–6×
   slower than it in the winning serialized-`chain` mode (~2× in
   event/cpu mode) at decode sizes, and is still slower at 4 MiB tensors,
   because serialized remote reads cost a nearly size-independent charge
   per op. Prefer fewer, fatter reduces (token batching), single fused
   kernels, or TP=2 over schedule cleverness. **Exception (measured):**
   pull-only recursive doubling over disjoint GPU pairs (2 ops and 2/3
   the bytes vs the naive 4-rank pull schedule) beats every naive
   variant at ≥ 1 MiB tensors — 1.34× at 1 MiB, 2.2× at 4 MiB — while
   still losing ~25–35% at 32 KiB decode sizes. Pick the schedule by
   tensor size; see the recursive-doubling follow-up.
   [TP-decode sim, 2-shot follow-up](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md#follow-up-2026-09-12-2-shot-all-reduce-reduce-scatter--all-gather-negative-result),
   [recdbl follow-up](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md#follow-up-2026-09-12-recursive-doubling--the-crossover-2-shot-never-reached).
5. **Don't bother with async compute/comm overlap engines.** A
   second-command-queue pipeline that pulls+sums partials chunk-by-chunk
   while the next chunk computes (`tp-sim --overlap on`) is never faster
   than the serialized baseline — the driver serializes every
   **remote-view** op behind compute (~200 µs/op, size-independent)
   regardless of which queue issues it, while a GPU-timestamp control
   shows the very same 2-queue overlap of *local* blits with compute
   works at full speed. The decode all-reduce tax cannot be hidden
   under compute on this driver; only the schedule (rule 4) and op
   count matter.
   [overlap follow-up](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md#follow-up-2026-09-12-computecomm-overlap-via-a-second-command-queue--negative-result).

## Topics

- Buffer placement strategies and `MTLHeap` partitioning per device
- Cost model of remote-VRAM paging vs. explicit copies (measure with `if-bench`)
- Cross-device synchronization patterns (see
  [../../examples/swift/if-peer-access](../../examples/swift/if-peer-access))
- Working-set sizing under `recommendedMaxWorkingSetSize` on 2×32 GB cards
