# probe-latency

Per-stage latency microbenchmarks for a **host-RAM relay all-reduce** —
the experiment that asks whether the AMD driver's ~200 µs per-remote-op
charge can be *dodged entirely* by routing the all-reduce through host
memory instead of over the Infinity Fabric remote views:

> GPU writes its partial to **its own** `storageModeShared` buffer +
> `encodeSignalEvent` → CPU polls `signaledValue` (cheap), sums the 4
> partials, writes each rank's buffer, `clflush`es every staging line,
> signals a CPU-set event → each consumer GPU's pre-committed command
> buffer (on a **second queue**) wakes on the event and copies
> host→VRAM.

Two findings make this mechanical, not magic — and both are coherence
traps (see
[gotchas](../docs/metal/gotchas.md)):

1. GPU→CPU completion must be signalled with **command-buffer event
   signaling** (a kernel-written flag races the payload: 60/60 stale
   reads). With event signaling the Xeon IOMMU does snoop GPU DMA, so
   **no CPU-side cache invalidation is needed** (`--noclinv` is safe and
   saves ~90 µs/reduce).
2. CPU→GPU writes are **invisible to GPU reads until cache eviction**
   (~9.6 ms!) — the CPU must `clflush` staging lines (≈1.3 µs/KiB)
   before signalling.

Probes (`--device`/`--remote` pick the pair; never use device 0):

| probe | measures |
|---|---|
| P1 | trivial command buffer commit→completion (driver floor, ~90 µs) |
| P2 | GPU→host: copy + event → CPU sees it; payload-freshness verify |
| P3 | host→GPU: CPU clflush + signal → GPU copy done (~80 µs with the flush fix) |
| P4 | full single-hop GPU→host→GPU relay e2e (~56–97 µs at 32 KiB) |
| P5 | incumbent: parallel remote-view read, 4 KiB–1 MiB |
| P6 (`--relay4`) | full 4-rank relay all-reduce loop with Σ-verify gate |

Results (32 KiB = batch-1 70B TP4 decode): relay4 **511 µs/reduce vs
naive+chain 619** — ~1.2×, but the CPU stage is O(ranks × bytes) and
the win dies by 64 KiB. Batch amortization remains the big decode
lever. Full numbers:
[`../../docs/benchmarks/raw/2026-09-12-probe-latency-relay.txt`](../../docs/benchmarks/raw/2026-09-12-probe-latency-relay.txt)
and the host-relay follow-up in the
[decode sim report](../../docs/benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md).

```
swift build --package-path tools -c release --disable-sandbox --product probe-latency
# single-hop probes (cross-card pair):
tools/.build/release/probe-latency --device 1 --remote 3 [--size-kib 32] [--noclinv]
# full 4-rank relay loop (ranks are --device,2,3,--remote):
tools/.build/release/probe-latency --relay4 --device 1 --remote 4 --iters 100 --noclinv
```

`--crossbuf` demonstrates the silent-corruption trap (one rank-0-owned
shared buffer encoded on all four devices: 3/4 ranks read garbage, no
error). `--crossview` shows remote views are private-buffers-only
(`newRemoteBufferViewForDevice:` returns nil for shared buffers).

Uses the `CFast` helper target for x86 `clflush` range maintenance.
