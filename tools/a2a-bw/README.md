# a2a-bw

Answers one question: **when several GPUs in an xGMI hive bulk-transfer at
the same time, is the Infinity Fabric Link bridge's capacity shared, or
does each GPU pair get its own?**

Method: bulk destination-side pulls (default 64 MiB × 8 rounds ≈ 512 MiB
per stream — deep in the bandwidth regime) through peer-group remote views,
in four phases:

| phase | streams | what it shows |
|---|---|---|
| A isolated | each pair alone | per-pair baseline |
| B jumper control | same-module pairs simultaneously | additive-scaling control (4 streams) |
| B2 cross-card 2 | one cross-card pair, both directions | linear-scaling check at low concurrency |
| B3 cross-card 4 | two disjoint cross-card pairs | concurrency-matched vs B: wiring or stream count? |
| C cross-card | all cross-module pairs simultaneously | 8-stream hive stress |
| D all-to-all | every ordered pair simultaneously | max hive stress |

Safety: never exceeds 3 consumers per source buffer (4+ hangs the
driver — see [gotchas](../../docs/metal/gotchas.md)); command buffers are
committed immediately.

```
usage: a2a-bw [--devices 1,2,3,4] [--modules 1,2|3,4]
              [--bytes N] [--rounds N] [--iters N] [--json]
```

Result on 2× W6800X Duo + bridge: hive capacity is **one shared ~90 GB/s
pool**, not per-pair bandwidth (Apple's 84 GB/s per direction is nowhere
reached under load). Aggregate scales linearly to 4 concurrent streams
(~24 GB/s each — same whether on-module or cross-card: B 90.5 vs B3
90.7) then collapses to ~51–55 GB/s at 8 streams with unfair,
unstable shares (driver scheduling, not link limits). The original
“independent/additive on-module jumper capacity” reading was a
stream-count artifact and has been retracted. Full analysis:
[bridge-share report](../../docs/benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
