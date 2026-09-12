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

## Follow-up (same day): kernel / fused pull modes — no change, and why

`tp-sim` gained `--pull blit|kernel|fused` to test whether moving the
fabric crossing from the copy engine to compute units (the toshllm
`ggml_metal_cpy_xdev_peer()` direction, or even a fully-fused
read-remote-and-sum kernel) speeds the decode reduce. Results at
hidden=8192, default schedule (`raw/` per-run JSON via `--json`; run
`tools/.build/release/tp-sim --pull <mode>`):

| `--pull` | load type | gate | chain µs/reduce | event µs/reduce |
|---|---|---|---|---|
| blit | copy engine | PASS | 748.2 (baseline table) | 3136.4 |
| kernel | `uint` (aligned) | PASS | 624.8 | 3257.2 |
| fused | `float` direct remote reads, no staging copy | PASS | 629.5 | 3265.3 |

All three are the same within run-to-run driver noise: the decode
all-reduce is **latency-bound** at 32 KiB, so the pull mechanism is
irrelevant — the scheduling lever (`chain` vs `event`) dominates by ~5×
and remains the only software knob that matters here.

A detour produced a lasting correctness rule: the first kernel-pull
implementation used `uchar4` loads and **failed the correctness gate**
(peer slots past the first vector read as never-written). Root cause:
misaligned 16-byte loads of remote views are served stale from a
non-snooped cache — the same bug that invalidated the first version of
the [ceiling report](2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).
The gate caught it because unlike pure bandwidth tests, it verifies
data. See [gotchas](../metal/gotchas.md) and
[`remote-view-check`](../../tools/remote-view-check/).

## Follow-up (2026-09-12): 2-shot all-reduce (reduce-scatter + all-gather) — negative result

`tp-sim` gained `--allreduce naive|twoshot|both` to test the classic
bandwidth-optimal all-reduce schedule: split the tensor into N shards;
in the **reduce-scatter** phase rank *r* pulls only shard-*r* of each
peer's partial and sums it; in the **all-gather** phase every rank pulls
the other ranks' finished shards and assembles the full sum. Theory: it
moves `2(N-1)/N` tensor-bytes per reduce across the fabric vs `(N-1)`
for the naive pull — **half the traffic at N=4**, at the cost of 6
remote ops per rank per reduce instead of 3, and one extra event-gated
dependency phase (three command buffers per rank: produce → RS → AG).

Measured at the decode config (hidden=8192 = 32 KiB tensor, 80 layers,
2 reduces/layer, 8 tokens; µs/reduce median; `--allreduce both`, one
run per pull engine; gate PASS on every schedule/engine combination,
including blit/kernel reads at non-zero slice offsets):

| `--pull` | schedule | fabric B/reduce/rank | chain | event | cpu |
|---|---|---|---|---|---|
| blit | naive | 98304 | **737** | 3226 | 3064 |
| blit | twoshot | 49152 | 4180 | 6475 | 6097 |
| kernel | naive | 98304 | **623** | 3294 | 3032 |
| kernel | twoshot | 49152 | 4022 | 6643 | 5435 |
| fused | naive | 98304 | **602** | 3198 | 3542 |
| fused | twoshot | 49152 | 3890 | 6603 | 6868 |

**2-shot is slower per reduce at every sync mode and pull engine —
~5–6× in the winning `chain` mode, ~2× in `event`/`cpu` — despite
moving half the bytes.** The naive baselines reproduce
the pull-mode follow-up numbers above, so the regression is entirely
the schedule.

Is it bytes or ops? Sweep the tensor size (blit, chain µs/reduce;
`raw/2026-09-12-tpsim-twoshot-blit{,-1mib,-4mib}.json`):

| tensor | naive B/rank | naive | twoshot B/rank | twoshot | naive/twoshot |
|---|---|---|---|---|---|
| 32 KiB | 96 KiB | 737 | 48 KiB | 4180 | 5.7× faster |
| 1 MiB | 3 MiB | 1273 | 1.5 MiB | 4584 | 3.6× faster |
| 4 MiB | 12 MiB | 2517 | 6 MiB | 5900 | 2.3× faster |

Closing the gap but never crossing over out to 4 MiB tensors. The
marginal cost per MiB is *higher* for 2-shot (~300 µs/MiB vs ~140–240
µs/MiB for naive), which kills the usual "crossover at large
messages" argument. The consistent explanation is the model this
driver has shown all along: **remote-view pulls cost a per-op
serialized charge (hundreds of µs) that is nearly size-independent
out to megabyte scale** (see the `pull-contention` section above and
the copy-paths latency floor). 2-shot doubles
the op count (6 vs 3 per rank per reduce) and adds a second
GPU-side dependency hop, so it pays two per-op taxes to save a byte
charge that this fabric barely bills.

Practical implications:

1. **Do not port 2-shot/all-reduce-decomposition schedules (NCCL-style
   reduce-scatter + all-gather, double binary tree, etc.) to this
   driver** — they all trade bytes for op count, and op count is what
   this driver charges for. This extends conclusion 3: minimize the
   number of remote ops per token, per *schedule*, not just per
   buffer.
2. A schedule that wins here must **cut ops**: fewer, fatter reduces
   (token-batching already does this), single-kernel fused pulls
   (verified equal here, fewer encodes), or TP=2 on one Duo where the
   op fan-in halves again.
3. The correctness result stands: the 2-shot machinery (shard-slice
   remote reads at non-zero offsets, per-shard views, three-phase event
   chain) is **functionally correct on this driver** — every gate
   passed, blit and kernel included — so it is available for
   byte-bound workloads (e.g. moving very large activations on
   a dedicated stream) even though it loses for decode.

## Follow-up (2026-09-12): recursive doubling — the crossover 2-shot never reached

`tp-sim` gained `--allreduce recdbl`: a **pull-only recursive doubling**
schedule for N=4. Two phases run over **disjoint full-duplex pairs** —
phase 1 over the same-module pairs (rank^1: dies 0↔1 and 2↔3), phase 2
over the cross-card pairs (rank^2: 0↔2 and 1↔3) — each rank doing one
read + local sum per phase via `fusedSum`/`sumN` with `np = 1`. Per
reduce per rank: **2 remote ops and 2×tensor bytes** (naive: 3 and 3;
twoshot: 6 and 1.5). Unlike 2-shot it cuts bytes *and* ops, and each
source buffer has exactly one remote reader per phase — so the fan-in
that makes `event` mode collapse never forms, while disjoint pairs sit
in the measured additively-scaling regime.

Decode config (hidden=8192 = 32 KiB; µs/reduce; `--allreduce all`;
gate PASS on every schedule/engine):

| `--pull` | schedule | best mode | µs/reduce | vs naive best |
|---|---|---|---|---|
| fused | naive | chain | **606** | — |
| fused | recdbl | event | 814 | 1.34× slower |
| fused | twoshot | chain | 3831 | 6.3× slower |
| blit | naive | chain | **737** | — |
| blit | recdbl | cpu | 929 | 1.26× slower |
| blit | twoshot | chain | 4101 | 5.6× slower |

(recdbl has no `chain` variant — its phases are already
contention-free by construction; the numbers above are each schedule's
*best* sync mode.) At decode tensor sizes the extra GPU-side dependency
hop (~200 µs) costs more than one saved remote op saves: **naive+chain
still wins at 32 KiB.**

But bytes are not free, and recdbl is where the schedule-vs-size
crossover finally appears (blit, µs/reduce, each schedule's best mode;
naive figures from the same-day sweep `raw/2026-09-12-tpsim-twoshot-blit*.json`):

| tensor | naive best (chain) | recdbl best | recdbl advantage |
|---|---|---|---|
| 32 KiB (70B decode) | 737 | 929 | — (naive) |
| 1 MiB | 1273 | 952 (cpu) | **1.34×** |
| 4 MiB (prefill-scale) | 2517 | 1147 (cpu) | **2.20×** |

2-shot's marginal cost per MiB was *higher* than naive's; recdbl's is
**much lower** (~30 µs/MiB from the 1→4 MiB points vs ~140 for naive),
so it crosses over between 32 KiB and 1 MiB and keeps widening. Mechanism matches the model: below the
crossover every schedule is per-op-charge dominated (op count and
dependency hops are everything); above it, bytes start to bill, and
recdbl moves 2/3 of naive's bytes on disjoint links at once (additive
capacity) while keeping one reader per buffer.

Note at 4 MiB recdbl's **cpu-barrier mode beats its event mode**
(1147 vs 2103): with events, phase 2 of reduce *u* overlaps phase 1 of
reduce *u+1*, whose sources overlap the still-active phase-2 reads —
re-introducing fan-in that the clean phase separation was designed to
avoid. At byte-bound sizes, keep the phases serialized.

Practical upshot for a llama.cpp/toshllm-style engine on this driver:

1. **Decode (32–64 KiB partials): keep the naive pull schedule with
   serialized pulls** — nothing tested beats ~600–740 µs/reduce.
2. **Prefill / batched tokens / any ≥ ~256 KiB–1 MiB partial: switch to
   recursive doubling on the module-disjoint pairs** — up to 2.2× at
   4 MiB and still growing with size.
3. A production engine should **pick the schedule by tensor size**
   (~256 KiB–1 MiB is the crossover zone; pin it per model config).

Raw: `raw/2026-09-12-tpsim-recdbl-{fused,blit}.json` (decode, `--allreduce
all`), `raw/2026-09-12-tpsim-recdbl-blit-{1mib,4mib}.json` (size sweep).
Repro: `tools/.build/release/tp-sim --allreduce all --pull fused`.

Raw: `raw/2026-09-12-tpsim-twoshot-{fused,blit,kernel}.json` (decode
config, `--allreduce both --sync both`) and
`raw/2026-09-12-tpsim-twoshot-blit-{1mib,4mib}.json` (size sweep,
`--layers 2..4 --tokens 2..3`). Repro:
`tools/.build/release/tp-sim --allreduce both --pull fused`.

## Follow-up (2026-09-12): compute/comm overlap via a second command queue — negative result

Every schedule so far bills the all-reduce *on top of* the layer's
compute. Real engines hide all-reduces under compute with an async
second stream. `tp-sim` gained `--overlap off|on|both` (naive schedule
only), `--compute-us US` (fake per-reduce GPU compute via a dependent-
FMA spin kernel that still writes the correctness value) and
`--overlap-chunks 2|4`:

- **off** — baseline: spin then pull+sum, all serialized on queue 1.
- **on** — partial produced in K chunks on queue 1; after chunk k lands
  (cross-rank `MTLSharedEvent`), every rank pulls+sums chunk k of every
  peer **on queue 2** while queue 1 computes chunk k+1.

A realistic C for 70B TP4 decode is ~300–500 µs/reduce (35 GB of
weights per die-quad ÷ 512 GB/s ÷ 160 reduces/token). The spin must be
calibrated **at the runtime dispatch config** (tg=64) with a refinement
round at the target duration — a cold long probe at a different config
mispredicted run durations ~2.5× and corrupted an early sweep.

Decode config (blit pull, hidden=8192 = 32 KiB, K=2, µs/reduce, verify
PASS in every cell; `raw/2026-09-12-tpsim-overlap-blit-{c0,c200,c500}.json`):

| C (µs/reduce) | off+chain | on+chain | off+event | on+event |
|---|---|---|---|---|
| 0    | **838**  | 1645 | 4236 | 5546 |
| 200  | **978**  | 1766 | 4578 | 5612 |
| 500  | **1341** | 2611 | 4800 | 5648 |

Fused pull at C=500: off+chain **1279**, on+chain 2677
(`raw/2026-09-12-tpsim-overlap-fused-c500.json`).

**Overlap never wins.** Two findings:

1. `off+chain ≈ C + ~840` — compute and comm already add ~1:1; with a
   serialized schedule the whole compute+comm chain costs their sum.
2. `on+chain ≈ off+chain + 0.8–1.3 ms` — the 2-queue/chunk machinery
   costs ~800–1200 µs/reduce at decode sizes (K=2 doubles the op count
   at the exact per-op charge the model says dominates, and the
   cross-rank chunk events add dependency hops) while hiding
   essentially *none* of the comm: on+chain grows with C just as fast
   as off+chain.

**Is that a queue-model limit or a remote-op limit?** A one-GPU control
(`tools/queue-control.swift`) settles it: a dependent-FMA spin on
queue 1 against a stream of 16 MiB *local* blits on queue 2, timed
with per-command-buffer GPU start/end timestamps. The spin's GPU busy
time is unchanged when the blits run concurrently (228–249 µs either
way), the blits add nothing measurable to wall time
(spin-alone 306–329 µs wall vs 311–321 µs with 2 blits queued on the
second queue vs 333–354 µs serialized on one queue), and even 4
queued blits hide under the spin (only mildly slowed at the margin).
**Queues do overlap compute and local blits.** (An earlier pass of
this control looked opposite; its blits were an overlapping, partly
out-of-range copy — undefined behaviour — and its per-op wall numbers
were junk. The timestamped v2 above is the real picture.)

So the driver *can* run a copy engine concurrently with compute; what
it refuses to overlap is **remote-view work**: every remote op takes
its serialized ~200 µs charge regardless of which queue issued it,
behind or in front of compute. Chunking makes that worse, not better,
because the charge is per-op.

Upshot: **on this driver you cannot hide a TP all-reduce under compute
with an async stream.** The decode comm tax (~600–740 µs × reduces per
token with naive+chain) is unavoidable headroom-wise; the only levers
left are the ones measured above — fewer/smaller remote ops
(recdbl once bytes dominate, prefill-scale and up) and reducing op
count itself. An engine should keep all-reduces on the critical path
and spend engineering effort on the schedule, not on async overlap.

Repro: `tools/.build/release/tp-sim --overlap both --compute-us 500
--pull blit` (and `--pull fused`); control:
`swiftc -O tools/queue-control.swift -o /tmp/queue-control &&
/tmp/queue-control` (uses device index 1, i.e. the first peer-group
GPU; never device 0, the display card).

## Follow-up (2026-09-12): batch amortization — quantifying the one big decode lever

Everything above attacks the *schedule* of a fixed 160-reduce,
batch-1 workload and finds the ~200 µs/op charge irreducible. But the
charge is per **op**, not per byte: a decode *batch* of B tokens shares
one all-reduce per reduce point instead of paying B of them. In
tp-sim terms, batched decode = the same 160 reduces with B× larger
tensors. (Note: `--tokens` is only a sample-count knob — it re-runs
per-token reduces, it does **not** model batching; batching is
`--hidden 8192×B`.)

Naive+chain, hidden=8192×B, µs/reduce and derived **comm-bound
ms/token = 160 × µs/reduce ÷ B**
(`raw/2026-09-12-tpsim-batch-amort-{blit,fused}-b{1,2,4,8,16,32}.json`):

| B | tensor | blit µs/red | blit ms/tok | fused µs/red | fused ms/tok |
|---|---|---|---|---|---|
| 1  | 32 KiB   | 704  | **112.7** | 590 | **94.5** |
| 2  | 64 KiB   | 734  | 58.8  | 615 | 49.2 |
| 4  | 128 KiB  | 766  | 30.6  | 640 | 25.6 |
| 8  | 256 KiB  | 847  | 16.9  | 683 | 13.7 |
| 16 | 512 KiB  | 955  | 9.5   | 781 | 7.8 |
| 32 | 1 MiB    | 1162 | 5.8   | 952 | **4.8** |

**Near-perfect amortization.** B=32 is 32× the bytes but only 1.6×
(blit) / 1.3× (fused) the per-reduce cost: **20–24× lower comm per
token.** At decode tensor sizes the transfer itself is noise next to
the fixed charge, so batching is almost pure win — the one lever this
driver leaves to decode, and it needs no schedule or engine cleverness
at all.

At B=32 the tensor reaches 1 MiB, where recdbl starts to matter:
recdbl+cpu ties fused naive+chain exactly (952 µs/red both, and beats
blit naive's 1162). At B=128 (4 MiB) recdbl+cpu runs 1270 µs/red =
**1.6 ms/token**, now decisively ahead of both naive baselines:
fused naive+chain 1902 (2.38 ms/token) and blit naive+chain 2517
(3.15 ms/token) — recdbl wins by **1.5×** over fused naive once bytes
fully dominate. Schedule crossover and batch amortization stack:
large-batch decode should use recdbl+cpu.
`raw/2026-09-12-tpsim-batch-amort-recdbl-b{32,128}.json`,
`raw/2026-09-12-tpsim-batch-amort-fused-b128.json`.

Caveats:

- These are **comm-bound** figures: real tokens/token is bounded below
  by compute, and batching multiplies per-GPU compute only if the
  engine's GEMMs become compute-bound; at modest B the compute cost
  grows much slower than comm shrinks, so the net moves with comm.
- Batch-1 interactive serving sees **no** change — the benefit needs
  B>1 real requests, or tricks that manufacture a batch: speculative
  / lookahead decoding (draft B tokens per verify pass), parallel
  sampling, or queueing.
- Repro: `tp-sim --hidden $((8192*B)) --tokens 1 --sync chain
  --pull fused` per B; `--allreduce recdbl --sync both` for the
  B≥32 rows.

## Follow-up (2026-09-12): host-RAM relay all-reduce — a real but small batch-1 win

The last idea that attacks the ~200 µs remote-op *charge* itself rather
than routing around it: keep GPUs off each other's memory entirely and
core out the all-reduce through host RAM — each GPU writes its partial
to **its own** `storageModeShared` buffer (host RAM, PCIe writes),
signals an `MTLSharedEvent`; the CPU (which is the host — reads are
free) sums the 4 partials, writes each rank's staging buffer back,
`clflush`es, signals a CPU-set event; each consumer GPU (command
buffer pre-committed on a **second queue** `encodeWaitForEvent`-ing
that event) copies host→VRAM and signals done. `probe-latency` measures
every constituent; `--relay4` runs the full 4-rank loop with a
correctness gate (Σ(r+1) expected, read back per rank).

### Coherence ground truth (this is the interesting part)

The Intel-host ↔ PCIe-GPU staging path is **not cache-coherent in the
way Apple Silicon's is**, and three distinct traps showed up:

1. **GPU→CPU payload/flag ordering.** A kernel writing payload then a
   flag (relaxed) into host RAM: the CPU saw the flag but read the
   **payload stale in 60/60 iterations** — GPU posted writes are not
   release-ordered against the flag. `encodeSignalEvent` on the command
   buffer (signal implies full memory flush) fixes it: 0/100 stale.
2. **GPU→CPU direction needs no CPU-side invalidation.** With event
   signaling, skipping `clflush`/`clinv` on the CPU side is safe on
   this Xeon (0/100 stale, PASS): platform IOMMU snoops invalidate CPU
   lines on GPU DMA. Saves ~90 µs/reduce.
3. **CPU→GPU is the broken direction.** A pre-committed GPU spin-kernel
   took **~9.6 ms** to observe a flag the CPU had just written — it
   waited for natural eviction of the dirty CPU cache line. Fix: CPU
   `clflush_range` over staging lines after writing (32 KiB ≈ 41 µs);
   GPU then sees it in normal time (P3 80 µs signal→done).

Two more driver gotchas found probing the broadcast optimization (see
[gotchas](../metal/gotchas.md)): a shared buffer **allocated on device
A and encoded into a kernel on device B** passes validation silently
and delivers garbage (3/4 ranks corrupt); and
`newRemoteBufferViewForDevice:` **returns nil for shared buffers**
(remote views are private/VRAM-only), so neither cross-device sharing
nor a remote-view escape hatch exists for host staging. Per-rank
staging buffers are mandatory.

### Results (32 KiB partials = batch-1 70B TP4 decode; µs/reduce)

| variant | µs/reduce | verify | vs naive+chain fused (619, same session) |
|---|---|---|---|
| relay4, per-rank staging + clinv | 599 | PASS | 1.03× |
| **relay4, per-rank staging, noclinv** | **511** | PASS | **1.21×** |
| relay4, crossbuf (illegal shared-buffer reuse) | 368 | **FAIL 3/4** | (silent corruption) |

Size sweep (noclinv) vs naive fused chain: 64 KiB — relay 753 vs 615
(loses); 128 KiB — relay 1212 vs ~640 (2× loss). The CPU stage is
O(ranks × bytes) cache-maintenance (read 4 partials cold, write 4,
clflush 4 ≈ 210 µs at 32 KiB, 432 at 64 KiB), so the win exists only
at batch-1 decode sizes and dies by B=2.

Single-hop costs for reference (32 KiB, cross-card): trivial CB floor
96 µs; GPU→host event→CPU-saw 66–86 µs (copy busy 8 µs); CPU-signal→
GPU-copy-done 80 µs; full one-hop relay e2e **56–97 µs** (verify PASS,
cross-card and same-module identical — it's all host RAM).

### Verdict

The remote-op charge **can** be dodged — a host-RAM relay all-reduce is
mechanically feasible, verified correct, and beats every fabric
schedule at batch 1 by ~20%. But it is not the hoped-for 6×: two
~90 µs command-buffer round-trips per hop and O(ranks × bytes) CPU
cache maintenance floor it near ~500 µs, and it pins a CPU core on the
all-reduce critical path. **Batch amortization (20–24× at B=32)
remains the dominant decode lever by an order of magnitude**; relay is
at best a niche add-on for latency-critical B=1 serving on this
driver. All measurements in
`raw/2026-09-12-probe-latency-relay.txt`; repro:
`swift build --package-path tools -c release --disable-sandbox --product probe-latency`
then `probe-latency --relay4 --device 1 --remote 4 --iters 100
--noclinv` (also `--device 1 --remote 3` single-hop probes,
`--size-kib`, `--crossbuf`, `--noclinv`).
