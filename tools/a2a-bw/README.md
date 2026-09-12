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

Result on 2× W6800X Duo + bridge (both engines, corrected measurements):
the per-**flow** ceiling is ~24 GB/s (blit) / ~29 GB/s (kernel);
disjoint GPU pairs scale additively (one full-duplex pair ~46–48 GB/s
alone, two disjoint pairs ~93–96 combined — there is no shared 90 GB/s
pool; "~90" is just 4 links × one flow). Two concurrent flows sharing
one link collapse below a single flow's rate, and ≥5 simultaneous
consumers get unstable, unfair shares; an app-side in-flight cap
(`--max-concurrent 4`) raises the 8-stream aggregate (~85→135 at
64 MiB kernel) but not the per-stream floor.

> **Engine warning (2026-09-12):** the kernel engine historically used
> `uchar4` loads. Misaligned 16-byte loads of remote views are served
> *stale* from a non-snooped cache (~113 fake GB/s) — every pre-fix
> `--engine kernel` number in this repo is invalid; see
> [gotchas](../../docs/metal/gotchas.md) and
> [`remote-view-check`](../remote-view-check/). The engine now uses
> `uint4` (16-byte aligned), which `remote-view-check` certifies as
> coherent. Note the kernel engine does **not** rewrite its source
> between iterations.

Full analysis:
[ceiling report v2](../../docs/benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)
and the blit-path [bridge-share report](../../docs/benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
