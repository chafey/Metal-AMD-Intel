# a2a-bw

Answers one question: **when several GPUs in an xGMI hive bulk-transfer at
the same time, is the Infinity Fabric Link bridge's capacity shared, or
does each GPU pair get its own?**

Method: bulk destination-side pulls (default 64 MiB × 8 rounds ≈ 512 MiB
per stream — deep in the bandwidth regime) through peer-group remote views,
as blit copies or kernel reads (`--engine kernel`), in phases:

| phase | streams | what it shows |
|---|---|---|
| A isolated | each pair alone | per-pair baseline |
| B jumper control | same-module pairs simultaneously | additive-scaling control (4 streams) |
| B2 cross-card 2 | one cross-card pair, both directions | linear-scaling check at low concurrency |
| B3 cross-card 4 | two disjoint cross-card pairs | concurrency-matched vs B: wiring or stream count? |
| C cross-card | all cross-module pairs simultaneously | 8-stream hive stress |
| E_cross_3/5/6 | N-prefix of a balanced cross-card order | stream-count sweep |
| E8_cross_..._cap4 | 8 cross-card streams, 4 in flight | app-side throttling vs full concurrency |
| D all-to-all | every ordered pair simultaneously | max hive stress |

Safety: never exceeds 3 consumers per source buffer (4+ hangs the
driver — see [gotchas](../../docs/metal/gotchas.md)); command buffers are
committed immediately.

```
usage: a2a-bw [--devices 1,2,3,4] [--modules 1,2|3,4]
              [--bytes N] [--rounds N] [--iters N]
              [--engine blit|kernel] [--max-concurrent N] [--phases A,B3] [--json]
```

`--phases` keeps only phases whose name contains one of the
comma-separated substrings; `--max-concurrent N` caps in-flight streams
with a semaphore in every concurrent phase.

Result on 2× W6800X Duo + bridge: the answer depends on the copy engine.
**Blit path:** one shared ~90 GB/s pool, linear to 4 streams then
collapsing at 8 — the ceiling is the copy engine, not the fabric.
**Kernel path:** ~113 GB/s on a single stream, ~90 GB/s *per direction*
on a full-duplex pair (Apple's 84 GB/s rating, honored), 330 GB/s
aggregate across four independent links; two concurrent flows sharing one
link collapse it to ~46 GB/s, so serialise per-link egress (a global
in-flight cap of 4 already beats full concurrency: 228 vs 185). Full
analysis: [ceiling report](../../docs/benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)
and the blit-path [bridge-share report](../../docs/benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
