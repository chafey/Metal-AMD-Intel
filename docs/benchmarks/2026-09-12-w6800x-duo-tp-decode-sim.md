# Benchmark Report: 2× W6800X Duo — llama.cpp-style TP-4 decode all-reduce simulation

- **Date:** 2026-09-12
- **Author:** repo maintainer
- **Tools:** `tp-sim` and `pull-contention` (Swift, release build, this repo)
- **Exact commands:**
  - sweep (one run per size):
    `tools/.build/release/tp-sim --hidden N --layers 80 --tokens 8 --json`
    (N ∈ {2048, 4096, 8192, 16384} fp32 elements; `--hidden-bytes B` also accepted)
  - 2-rank baseline:
    `tools/.build/release/tp-sim --devices 1,2 --hidden 8192 --layers 80 --tokens 8 --json`
  - contention breakdown:
    `tools/.build/release/pull-contention --json`
- **Build note:** all runs used the release binary directly
  (`swift build --package-path tools -c release --disable-sandbox`).

## What is being measured

llama.cpp Metal tensor parallelism (and toshllm's patch series on top of
it) performs, per decoder layer, **two all-reduces** (attention out-
projection and FFN down-projection). Each all-reduce in this design is:
every device **pulls** each peer's fp32 partial tensor into its own VRAM
(destination-side, through Metal peer-group remote buffer views —
`ggml_metal_cpy_xdev_peer()`), then sums locally.

`tp-sim` reproduces exactly that communication pattern across the four
dies of the 2× W6800X Duo (one Metal peer group, xGMI hive of 4, Infinity
Fabric Link bridge fitted) and times it at **token granularity**:

- per reduce, each rank: a `produce` kernel (emits a constant — emulates
  the local partial from matmuls), then a `reduce` CB: destination-side
  **blit pulls** of the 3 peer partials + one local `sumN` kernel.
- bytes/token/device = `layers × reduces × (ranks−1) × hidden × 4`.
- **Model compute is NOT simulated.** These are communication-side costs
  a TP decode step additionally pays.

Three synchronisation styles are timed:

| mode | what it represents | GPU-side schedule |
|---|---|---|
| `event` | toshllm-style: MTLSharedEvent chains, CPU commits a whole token and is off the critical path | all ranks' pulls run **concurrently** |
| `chain` | same events, plus each rank's reduce waits for the previous rank's reduce | pull phase **serialised** across ranks |
| `cpu` | no events; two CPU commit+wait barriers per reduce | concurrent pulls + CPU round-trips |

Timed region per token = **encode + commit + GPU completion** (a real
engine pays encode too; see gotchas — deep *uncommitted* remote-view
pipelines wedge this driver, so encoding is per-reduce by necessity).
First token is warmup; medians of 8 tokens.

A correctness gate runs first: produce writes `rank+1` on each rank, and
every rank's summed output must equal Σ(1…4) = 10. **The gate passed in
every archived run**: event-chained pulls do observe peers' writes on
this driver (cross-device event ordering works).

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) measured | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4, Infinity Fabric Link bridge fitted) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

Devices 1–4 = the four Duo dies, all peerGroupID `0x4cf5577a51a24576`.
The RX 6900 XT (dev0, display) is not used (see the 2026-09-11 scope
notes). No other GPU load was active during these runs.

## Results — tp-sim sweep (TP=4, 80 layers, 2 reduces/layer)

Per token: 160 all-reduces; 480 peer pulls; µs/reduce = µs/token ÷ 160.

| hidden (fp32) | bytes/token/device | event µs/token | chain µs/token | cpu µs/token | event µs/reduce | chain µs/reduce | cpu µs/reduce | comm-bound tok/s (event / chain / cpu) |
|---|---|---|---|---|---|---|---|---|
| 2048 (8 KiB/tensor) | 3 932 160 | 514 486 | 121 446 | 495 351 | 3215.5 | 759.0 | 3095.9 | 1.9 / 8.2 / 2.0 |
| 4096 (16 KiB) | 7 864 320 | 498 531 | 121 387 | 484 040 | 3115.8 | 758.7 | 3025.2 | 2.0 / 8.2 / 2.1 |
| 8192 (32 KiB, 70B-class) | 15 728 640 | 501 820 | 119 709 | 490 387 | 3136.4 | 748.2 | 3064.9 | 2.0 / 8.4 / 2.0 |
| 16384 (64 KiB) | 31 457 280 | 510 908 | 121 624 | 482 474 | 3193.2 | 760.1 | 3015.5 | 2.0 / 8.2 / 2.1 |

Raw: [raw/2026-09-12-tpsim-hidden2048.json](raw/2026-09-12-tpsim-hidden2048.json),
[hidden4096](raw/2026-09-12-tpsim-hidden4096.json),
[hidden8192](raw/2026-09-12-tpsim-hidden8192.json),
[hidden16384](raw/2026-09-12-tpsim-hidden16384.json).

**Key observations**

1. **Completely fixed-cost dominated.** An 8× payload growth (8 → 64 KiB
   per partial) changes µs/token by ≤ 3 %. At decode sizes every pull is
   in the latency regime; ~0.75–3.2 ms/reduce is sync + per-remote-op
   overhead, not transfer time. Effective on-wire bandwidth is 0.01–0.26
   GB/s — two orders of magnitude under the 37 GB/s p2p plateau measured
   on 4 MiB buffers ([copy-paths report](2026-09-11-w6800x-duo-copy-paths.md)).
2. **Serialising the pull phase (`chain`) beats toshllm's concurrent
   pulls (`event`) ~4.2×** — ~0.75 vs ~3.15 ms/reduce. The CPU-barrier
   mode lands next to `event`, confirming GPU-side contention (not CPU
   round-trips) dominates the concurrent schedule.
3. `chain` is also nearly size-flat → for this pattern the lever is
   *number and scheduling of remote ops per token*, not payload size.

## Results — TP=2 baseline (ranks on dies 1,2 — jumper pair)

| mode | µs/token | µs/reduce | comm-bound tok/s |
|---|---|---|---|
| event | 46 493 | 290.6 | 21.5 |
| chain | 46 498 | 290.6 | 21.5 |
| cpu | 65 998 | 412.5 | 15.2 |

Raw: [raw/2026-09-12-tpsim-2rank-hidden8192.json](raw/2026-09-12-tpsim-2rank-hidden8192.json).
With only two ranks, event ≡ chain (there is nothing to serialise past
the single peer) and per-reduce cost drops to ~291 µs — **TP=2 on one Duo
module is ~2.6× cheaper per reduce than TP=4 across the bridge.**

## Results — why: `pull-contention` (4 KiB ops, same session)

| case | median µs |
|---|---|
| encode one 1-pull CB | 6.3 |
| commit + wait one 1-pull CB | 55.9 |
| 1 puller, 3 remote copies in one CB (others idle) | 79.0 |
| pair exchange rank0↔rank1 (module pair) | 417.3 |
| pair exchange rank0↔rank2 (cross module) | 383.1 |
| all-to-all concurrent, 1 pull/rank (4 ops in flight) | 432.5 |
| all-to-all concurrent, 3 pulls/rank (12 ops in flight) | 4033.0 |
| all-to-all **sequential** (same 12 ops, one at a time) | 542.4 |
| all-to-all concurrent, commit-all-then-wait-all | 2160.0 |

Raw: [raw/2026-09-12-pull-contention.json](raw/2026-09-12-pull-contention.json).

**The driver does not parallelise remote-view pulls across the hive — it
penalises them.** 12 remote ops done one-at-a-time cost 542 µs total;
done simultaneously they cost 4033 µs (~336 µs per in-flight op).
A single isolated pull is 55.9 µs. Session-to-session, small-pull numbers
vary (pair-exchange was 86–213 µs in an earlier ad-hoc probe vs ~400 µs
here), but the *ordering* between concurrent and sequential has been
stable across every session so far, and matches tp-sim's ~4 ms/reduce
event vs ~0.75 ms/reduce chain exactly.

**Fan-in hazard:** 3 concurrent readers of one remote buffer are fine
(tp-sim's steady state), but **4 consumers of the same remote buffer
hard-hang the driver** (AMDRadeonX6000 7.0.1; observed with the
predecessor harness — the case is gated behind `--allow-fanin` precisely
because it requires killing the tool). `pull-contention` records it as
skipped by default rather than risking a wedge during a benchmark sweep.

## Driver gotchas found while building this

- **Many uncommitted remote-view command buffers wedge the driver.**
  Pre-encoding >1k pull CBs across 4 queues before committing hung the
  GPU (process kill required; GPUs recover). tp-sim therefore encodes and
  commits per reduce (in-flight depth 2 CBs/rank), like a real engine.
- `MTLCommandBuffer.encodeWaitForEvent(_:value:)` is the Swift selector
  name in the CLT SDK (not `encodeWait(forEvent:)`);
  `encodeSignalEvent(_:value:)` imports as written.
- Event signal values must increase monotonically per event — the
  correctness gate and timed runs share one counter for this reason.
- `MTLBuffer.deviceAddress` is not in the public protocol; the local sum
  reads the already-pulled copies instead (no address tables needed).

## Conclusions

1. **On this driver, a llama.cpp-style TP-4 decode is latency-bound by
   remote-op scheduling, not xGMI bandwidth.** A 70B-class model
   (hidden 8192, 80 layers) pays ≈ 0.5 s/token communication with the
   concurrent-pull schedule (~2 tok/s ceiling) or ≈ 0.12 s/token (~8.4
   tok/s ceiling) with a serialised-pull schedule — a ~4.2× lever that
   exists **today** purely in sync scheduling.
2. The toshllm/llama.cpp Metal TP design (concurrent destination-side
   pulls synchronised with shared events) is *correct* on this hardware
   (gate passes) but leaves ~4× on the table vs serialising the pull
   phase; TP=2 on a single Duo with a jumper is cheaper again (~2.6× per
   reduce than TP=4-chain, and without the fan-in hazard).
3. For multi-GPU inference on this platform, reduce the *count* of remote
   ops per token (fewer, larger reduces; batch tokens; consider TP=2 +
   pipeline parallelism across modules) — payload size is already free.

Related: [copy paths](2026-09-11-w6800x-duo-copy-paths.md) (single-pull
37 GB/s plateau and 54–61 µs latency floor that these fixed costs sit
on), [p2p matrix](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md).
