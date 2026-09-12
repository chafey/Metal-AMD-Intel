# tp-sim

Simulates and measures the communication a **llama.cpp / toshllm Metal
tensor-parallel decode step** pays on a group of peer GPUs (default: the
four dies of 2× W6800X Duo joined by an Infinity Fabric Link bridge).

Pattern replicated: per layer, 2 all-reduces (attention out-proj, FFN
down-proj); each all-reduce = every rank **pulls** each peer's fp32
partial through Metal peer-group remote buffer views (destination-side,
`ggml_metal_cpy_xdev_peer()` equivalent) and sums locally. Model compute
is not simulated — results are the communication-side cost per token.

Three synchronisation styles are timed per token:

- `event` — MTLSharedEvent chains (toshllm style): all ranks' pulls run
  concurrently, CPU is off the critical path.
- `chain` — same events, but each rank's reduce also waits for the
  previous rank's reduce: the pull phase is serialised across ranks.
  Measured ~4× faster than `event` on AMDRadeonX6000 7.0.1 (the driver
  penalises concurrent remote-view pulls; see
  [pull-contention](../pull-contention/)).
- `cpu` — two CPU commit+wait barriers per reduce (no events).

A correctness gate runs first: each rank produces `rank+1`, and every
rank's all-reduce result must equal Σ(1…N). This catches drivers where
cross-device event ordering "works" but does not actually make peer
writes visible.

Three pull styles are selectable (`--pull`):

- `blit` (default) — copy-engine pull into local VRAM, then `sumN`.
- `kernel` — compute-unit pull into local VRAM (full-grid `uint` loads),
  then `sumN`.
- `fused` — one kernel reads the remote views directly and writes only
  the sum (no local staging copy).

All three pass the correctness gate and all three cost the **same** per
reduce (~625 µs chain, ~3.3 ms event at hidden=8192): at decode tensor
sizes the reduce is latency-bound, so the pull path does not matter.
Kernel/fused loads MUST use naturally aligned types — `uchar4` loads of
remote views return stale data ([gotchas](../../docs/metal/gotchas.md)).

```
usage: tp-sim [--devices 1,2,3,4] [--hidden N | --hidden-bytes B]
              [--layers L] [--reduces R] [--tokens T]
              [--sync cpu|event|chain|both] [--pull blit|kernel|fused] [--json]
```

Timed region = encode + commit + GPU completion. Command buffers are
encoded and committed per reduce: keeping >1k remote-view CBs
*uncommitted* across the hive wedges the AMD driver (documented in
[docs/hardware/infinity-fabric.md](../../docs/hardware/infinity-fabric.md)).

Results:
[docs/benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md](../../docs/benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md).
