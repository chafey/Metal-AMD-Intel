# pull-contention

Characterises how the AMD MPX driver handles **concurrent destination-side
pulls through Metal peer-group remote buffer views** — the primitive
tensor-parallel all-reduces are built on. Explains why
[`tp-sim`](../tp-sim/)'s concurrent-pull mode is ~4× slower than its
serialised-pull mode.

Cases (all small copies, latency regime; medians over repeats):

| case | shows |
|---|---|
| baseline encode / commit+wait | the ~6 µs encode and ~56 µs isolated-pull floor |
| 1 puller, N−1 remote copies, others idle | multi-source pulls are cheap when uncontended |
| pair exchange (module pair / cross module) | two-way concurrency is near-free |
| all-to-all concurrent (1 or N−1 pulls/rank) | the penalty: ~100–340 µs per *in-flight* remote op |
| all-to-all sequential | the same ops one-at-a-time cost ~1/7 the wall time |
| commit-all then wait-all | contention is GPU-side, not a CPU-serialisation artefact |
| fan-in (opt-in `--allow-fanin`) | **4 consumers of one remote buffer hard-hang the driver** (AMDRadeonX6000 7.0.1); 3 are safe |

The fan-in case is skipped by default because reproducing it wedges the
GPU until the process is killed (the GPUs recover; no reboot needed).

```
usage: pull-contention [--devices 1,2,3,4] [--bytes N] [--iters N]
                       [--allow-fanin] [--json]
```

Results:
[docs/benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md](../../docs/benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md).
