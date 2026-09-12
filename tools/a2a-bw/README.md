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
| B jumper control | same-module pairs simultaneously | additive baseline over physically independent links |
| C cross-card | all cross-module pairs simultaneously | the bridge-sharing measurement |
| D all-to-all | every ordered pair simultaneously | max hive stress |

Safety: never exceeds 3 consumers per source buffer (4+ hangs the
driver — see [gotchas](../../docs/metal/gotchas.md)); command buffers are
committed immediately.

```
usage: a2a-bw [--devices 1,2,3,4] [--modules 1,2|3,4]
              [--bytes N] [--rounds N] [--iters N] [--json]
```

Result on 2× W6800X Duo + bridge: the bridge **is** one shared link
(~51–54 GB/s aggregate for 8 simultaneous cross-card streams, ~85–89 GB/s
combined bidirectional — *not* Apple's 84 GB/s per direction), while the
on-module jumpers stay independent and additive. Full analysis:
[bridge-share report](../../docs/benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
