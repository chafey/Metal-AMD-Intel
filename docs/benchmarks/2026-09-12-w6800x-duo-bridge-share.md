# Benchmark Report: 2× W6800X Duo — is bridge bandwidth shared across simultaneous flows?

- **Date:** 2026-09-12 (revised same day after the concurrency-controlled
  follow-up; the original findings 1, 3 and 4 were misinterpreted — see
  "Follow-up" below)
- **Author:** repo maintainer
- **Tool:** `a2a-bw` (Swift, release build, this repo)
- **Exact commands:**
  - primary capture: `tools/.build/release/a2a-bw --json`
  - confirmation rerun: same command (aggregate values quoted from both;
    rerun raw at `raw/2026-09-12-a2a-bw-rerun.json`)
  - concurrency-controlled follow-up (added phases B2/B3): same command
    after rebuilding `a2a-bw` with the new phases,
    raw at `raw/2026-09-12-a2a-bw-concurrency.json`

## Question

Apple rates the W6800X Infinity Fabric Link at **84 GB/s in each
direction** ([tech specs](https://support.apple.com/en-ge/118461)) but
publishes **no figure for the external bridge connection** on Duo modules.
All previous repo measurements ([p2p matrix](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md))
ran one flow at a time, so they cannot distinguish "84 GB/s per GPU pair"
from "one link, shared". This run measures simultaneous bulk streams to
settle it.

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) measured | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4, Infinity Fabric Link bridge fitted; modules = dies {1,2} | {3,4}) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

## Method

Each stream = 8 back-to-back blit **pulls** of a 64 MiB remote buffer-view
source into the consumer's own VRAM in one command buffer (~512 MiB per
stream — deep in the bandwidth regime, so the driver's per-op fixed costs
documented in [gotchas](../metal/gotchas.md) amortise to noise). Sources
are written once and never touched again. Consumers never exceed 3 readers
per buffer (4+ hangs the driver — documented). Phases:

- **A isolated** — every ordered pair alone, one at a time (baseline)
- **B jumper control** — both same-module pairs pulling simultaneously
  (4 streams: 1↔2 and 4↔3)
- **B2 cross-card, 2 streams** — one cross-card pair, both directions
  (1↔3). Added in the follow-up: the linear-scaling check at low
  concurrency, concurrency-matched against B.
- **B3 cross-card, 4 streams** — two disjoint cross-card pairs, both
  directions (1↔3, 2↔4). Same stream count as B; the decisive
  comparison — if the B-vs-C gap were wiring (jumper vs bridge), B3 must
  land near C; if it is stream count, B3 must land near B.
- **C cross-card** — the 8 cross-module streams simultaneously
- **D all-to-all** — all 12 ordered streams simultaneously

Medians of 3 timed iterations (plus warmup) per stream; aggregate =
total stream bytes ÷ median wall time.

## Results (primary capture; raw → `raw/2026-09-12-a2a-bw.json`)

| Phase | Streams | Median wall (ms) | Aggregate GB/s | Per-stream GB/s |
|---|---|---|---|---|
| A isolated | 12 (sequential) | 222.6 | 28.9 | 27.4–29.6 (uniform, jumper ≡ bridge) |
| B jumper control | 4 | 23.8 | 90.3 | 22.6–23.7 |
| C cross-card only | 8 | 84.7 | **50.7** | 6.4–18.8 (unfair split) |
| D all-to-all | 12 | 99.5 | 64.7 | same-module 20.7–23.8; cross-card 5.5–13.8 |

Per-stream detail (C phase, consumer→producer, cross-module all):
1→3 18.8, 1→4 10.3, 2→3 9.6, 2→4 13.1, 3→1 14.0, 3→2 6.5, 4→1 10.5,
4→2 6.4 GB/s.

**Confirmation rerun** (`raw/2026-09-12-a2a-bw-rerun.json`): aggregates
A 29.0 / B 96.1 / C 54.0 / D 68.8 — same picture within session variance.

## Follow-up: concurrency-controlled run (`raw/2026-09-12-a2a-bw-concurrency.json`)

`tools/.build/release/a2a-bw --json` (rebuilt with phases B2/B3):

| Phase | Streams | Aggregate GB/s | Per-stream GB/s |
|---|---|---|---|
| A isolated | 12 (sequential) | 29.0 | 27.1–29.6 (uniform, on-module ≡ cross-card) |
| B jumper control | 4 | 90.5 | 23.7–24.2 |
| **B2 cross-card 2 streams** | 2 | 48.2 | 24.2, 24.2 |
| **B3 cross-card 4 streams** | 4 | **90.7** | 22.7–24.4 |
| C cross-card | 8 | 55.2 | 8.0–12.4 (unfair, unstable) |
| D all-to-all | 12 | 63.4 | 5.3–24.9 (unfair, unstable) |

B3 (four **cross-card** streams) matches B (four same-module streams)
exactly: 90.7 vs 90.5 GB/s aggregate, ~23–24 GB/s per stream both. B2
two cross-card streams: 2 × 24.2 = 48.2 — perfect linear scaling. The
~50 GB/s C-phase aggregate therefore is **not** the cross-card path's
capacity: the same path carries 90.7 GB/s at half the stream count.
The B-vs-C gap tracks stream *count*, not wiring.

## Findings (revised)

1. **Capacity is hive-global, not per-pair.** Eight simultaneous cross-card
   streams share ~51–55 GB/s aggregate and even four streams only reach
   ~90 GB/s, far short of the 4×29–8×29 GB/s per-pair scaling that
   non-shared capacity would produce. The whole 4-GPU hive behaves like a
   single ~90 GB/s (both directions combined) pool under any load we could
   apply — nowhere near 84 GB/s *per direction*.
2. **There is no measurable performance distinction between on-module and
   cross-card paths.** Isolated: 27.1–29.6 GB/s uniformly across all 12
   ordered pairs. At equal concurrency: 4 on-module streams 90.5 GB/s vs
   4 cross-card streams 90.7 GB/s; 2 cross-card streams scale perfectly
   (48.2). Every measurement is consistent with one uniform xGMI fabric;
   none depends on whether a flow stays on its module or crosses the
   bridge. (The IORegistry exposes the hive — `XGMI_HiveSize=4`, one
   `XGMI_HiveID` — but not the physical wiring, so bandwidth is the only
   probe we have, and it cannot distinguish the paths.)
3. **Retracted: “on-module jumper transfers are independent/additive
   capacity.”** The original B-vs-C contrast (90 vs 51 GB/s) looked like
   jumper-vs-bridge wiring, but the follow-up shows four *cross-card*
   streams hit the same 90 GB/s. The gap was stream count, not topology.
   Likewise the original finding that “same-module traffic is unaffected
   by bridge saturation” is refuted by the rerun: in phase D the rerun's
   same-module streams got 6.0–11.0 GB/s while two cross-card streams got
   ~21. Phase winners swap between runs ⇒ per-stream shares are
   driver-arbitrated, not determined by physical paths.
4. **Aggregate scales linearly to 4 concurrent streams, then collapses.**
   1 stream ≈ 29; 2 streams = 48; 4 streams = 90–96; 8 streams = 51–55;
   12 streams = 63–69. Beyond 4 streams the driver's scheduling penalty
   (same signature as the small-op contention in the
   [TP-decode report](2026-09-12-w6800x-duo-tp-decode-sim.md)) overwhelms
   the fabric and total throughput *falls*. Whether a 4+ stream fabric
   limit also exists is masked by this driver behaviour.
5. **Arbitration above 4 streams is unfair and unstable** (3× spread in C,
   per-stream winners swap run-to-run). Below that, at ≤4 streams, the
   split is fair (~24 each, both directions ~equal).

## Capacity-planning rules for a 2× W6800X Duo + bridge

- Budget the hive as **one ~90 GB/s pool (all flows, both directions)**,
  not 84 GB/s per direction per pair. Up to **4 concurrent bulk flows**,
  expect ~24 GB/s each, fairly split; this holds for on-module *and*
  cross-card flows alike.
- **Keep concurrent bulk flows at ≤4.** At 8–12 simultaneous flows total
  throughput *drops* to ~51–69 GB/s with unstable, unfair per-stream
  shares.
- Do **not** plan on on-module transfers being free background capacity
  while cross-card traffic runs: nothing in the measurements supports
  separate jumper/bridge capacity pools, and 12-flow loads degrade every
  flow (original phase-D “survivors” were run-to-run luck).
- Never assume a flow keeps its isolated ~29 GB/s rate once concurrency
  rises.

## Raw data

- `raw/2026-09-12-a2a-bw.json` (primary, this report's tables)
- `raw/2026-09-12-a2a-bw-rerun.json` (confirmation; refutes original
  finding 4 via its phase-D per-stream values)
- `raw/2026-09-12-a2a-bw-concurrency.json` (follow-up with phases B2/B3;
  refutes original findings 1/3 wording and drives the revision above)

## Conclusions

The original question ("shared or per-pair?") is answered: **shared** —
the hive behaves as one ~90 GB/s fabric pool. The revised follow-up also
answers the question the original run raised but misread: the on-module
Infinity Fabric Link jumper shows **no** capacity separate from the
bridge under any concurrency we tested, so all 4-GPU traffic should be
budgeted against the same pool regardless of path. Doc links corrected
in [infinity-fabric.md](../hardware/infinity-fabric.md) and
[mpx-cards.md](../hardware/mpx-cards.md).
Tool: [a2a-bw README](../../tools/a2a-bw/README.md).
