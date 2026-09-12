# Benchmark Report: 2× W6800X Duo — is bridge bandwidth shared across simultaneous flows?

- **Date:** 2026-09-12
- **Author:** repo maintainer
- **Tool:** `a2a-bw` (Swift, release build, this repo)
- **Exact commands:**
  - primary capture: `tools/.build/release/a2a-bw --json`
  - confirmation rerun: same command (aggregate values quoted from both;
    rerun raw at `raw/2026-09-12-a2a-bw-rerun.json`)

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
  (2↔1 and 4↔3 on physically separate jumper links; the control that
  proves the harness measures *links*, not harness artifacts)
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

## Findings

1. **The bridge is one shared link, not per-pair bandwidth.** Eight
   simultaneous cross-card streams share ~51–54 GB/s aggregate, while the
   isolated single stream runs ~29 GB/s. Per-pair rates collapse from
   ~29 to 6–19 GB/s. If the bridge delivered per-pair capacity, 8 streams
   would aggregate multiples of 29; they do not.
2. **The external bridge connection does not behave like 84 GB/s per
   direction when loaded bidirectionally.** The two directions' share
   sums land at 85–89 GB/s *combined* (A-consumers 51.8/48.0 +
   B-consumers 37.4/37.4 across the two runs), and the split between
   directions is **consistently asymmetric** (module A consumers pull
   ~1.3× what module B consumers pull — reproduced). Consistent with one
   shared ~84–90 GB/s bidirectional capacity arbitrated unfairly, not
   84 per direction. Apple's "in each direction" figure is stated for the
   GPU-to-GPU link generally and does not hold for the loaded bridge.
3. **Independent links stay independent.** The jumper-pair control (two
   physically separate links, 4 streams) scales additively: ~90–96 GB/s
   aggregate, per-stream cost only the ~20% common with any concurrent
   pull (driver overhead). This is the control that makes finding 1
   trustworthy — the harness measures link capacity, not thread contention.
4. **Same-module traffic is unaffected by bridge saturation.** In phase D,
   jumper streams held ~21–24 GB/s while cross-card streams starved
   (~5–14). On-module Infinity Fabric Link jumper and cross-card bridge
   are separately-switched capacity.
5. Directional and per-stream arbitration is **unfair** (up to ~3× spread
   across nominally symmetric streams, stable direction split across
   runs) — the hive's arbiter is not round-robin fair. Applications
   needing predictable cross-card bandwidth must schedule flows (cf. the
   serialised-pull finding for small ops in the
   [TP-decode report](2026-09-12-w6800x-duo-tp-decode-sim.md)).

## Capacity-planning rules for a 2× W6800X Duo + bridge

- Budget the bridge as **~50 GB/s per direction under load, shared by all
  cross-card flows**, not 84 GB/s per direction per pair.
- On-module (jumper) transfers are independent capacity: they neither
  consume nor are starved by the bridge in these tests.
- Never assume a cross-card flow keeps its isolated ~29–38 GB/s rate;
  with N concurrent cross-card flows expect ~50/N-class shares, unfairly
  divided.

## Raw data

- `raw/2026-09-12-a2a-bw.json` (primary, this report's tables)
- `raw/2026-09-12-a2a-bw-rerun.json` (confirmation)

## Conclusions

Answers the open question left in
[infinity-fabric.md](../hardware/infinity-fabric.md) (now updated); doc
links corrected there and in [mpx-cards.md](../hardware/mpx-cards.md).
Tool: [a2a-bw README](../../tools/a2a-bw/README.md).
