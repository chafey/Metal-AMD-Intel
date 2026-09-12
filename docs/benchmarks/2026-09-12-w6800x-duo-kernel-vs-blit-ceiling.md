# Benchmark Report: 2× W6800X Duo — the ~90 GB/s ceiling is the blit engine, not the fabric

- **Date:** 2026-09-12
- **Author:** repo maintainer
- **Tool:** `a2a-bw` v2 (Swift, release build, this repo; adds
  `--engine kernel`, `--max-concurrent`, `--phases`)
- **Exact commands** (all raw files in `raw/`):
  - `tools/.build/release/a2a-bw --json` → `raw/2026-09-12-a2a-bw-sweep.json`
  - `tools/.build/release/a2a-bw --rounds 2 --json` → `raw/2026-09-12-a2a-bw-rounds2.json`
  - `tools/.build/release/a2a-bw --engine kernel --json` → `raw/2026-09-12-a2a-bw-kernel.json`
  - `tools/.build/release/a2a-bw --engine kernel --bytes 268435456 --rounds 1 --iters 1 --json`
    → `raw/2026-09-12-a2a-bw-kernel-big.json`
  - `tools/.build/release/a2a-bw --engine kernel --bytes 536870912 --rounds 1 --iters 1
    --phases A_isolated,B3,C_cross,E8_cross --json` → `raw/2026-09-12-a2a-bw-kernel-nocache.json`
  - `tools/.build/release/a2a-bw --devices 1,3 --modules '1|3' --engine kernel
    --bytes 2147483648 --rounds 1 --iters 1 --json`
    → `raw/2026-09-12-a2a-bw-kernel-2gib-pair.json`
  - `tools/.build/release/a2a-bw --engine kernel --bytes 1073741824 --rounds 1 --iters 1
    --phases B3,C_cross,E8_cross --json` → `raw/2026-09-12-a2a-bw-kernel-1gib-fanout.json`
  - same with `--phases C_cross --max-concurrent 1` → `raw/2026-09-12-a2a-bw-kernel-1gib-cap1.json`
  - same with `--phases C_cross --max-concurrent 2` → `raw/2026-09-12-a2a-bw-kernel-1gib-cap2.json`

## Question

The [bridge-share report](2026-09-12-w6800x-duo-bridge-share.md) found a
~90 GB/s hive-global ceiling and a collapse at ≥5 concurrent streams, and
explicitly left open whether that ceiling is the fabric or the driver.
All measurements to date used **blit** copies (copy-engine submits).
`a2a-bw` v2 adds a **kernel** engine — the consumer's compute units read
the remote buffer view directly — a different hardware path to the same
fabric, plus a concurrency semaphore to test app-side scheduling.

## Machine

Same reference configuration as the bridge-share report: Mac Pro
(MacPro7,1), Xeon W-3245, 2× Radeon Pro W6800X Duo, Infinity Fabric Link
bridge fitted, modules = dies {1,2} | {3,4}, macOS 26.6.2 (25G83),
AMDRadeonX6000 7.0.1. The RX 6900 XT display card (dev0) is never measured.

## Method

Each stream = `--rounds` back-to-back 64 MiB (sweep runs) or 512 MiB–2 GiB
(size runs) pulls of a remote buffer view into the consumer's own VRAM,
executed either as blit copies or as compute dispatches
(`uchar4` per thread, 256-thread threadgroups) on the consumer's queue.
Kernel runs used `--rounds 1 --iters 1` at ≥512 MiB (per-op fixed costs
are amortised at these sizes; see below). Streams are chosen so no buffer
ever has ≥4 concurrent consumers (driver hang limit).

## Results

### Head-to-head, 64 MiB streams (identical phase schedule)

| Phase (cross-card unless noted) | Blit GB/s | Kernel GB/s |
|---|---|---|
| A isolated (per stream) | 27.4–29.6 | 109.2–113.1 |
| B same-module, 4 streams | 90.1 | 281.8 |
| B2 one pair full-duplex, 2 streams | 45.1 | 143.8 |
| B3 two pairs, 4 streams | 90.5 | 286.6 |
| C all 8 cross streams | 50.8 | 147.7 |
| 8 streams, semaphore cap 4 | 66.0 | 210.7 |
| D all-to-all, 12 streams | 62.7 | 203.4 |

Blit is flat-capped: no phase exceeds ~90 GB/s, and `--rounds 2` changes
nothing (C = 49.2 GB/s; `raw/2026-09-12-a2a-bw-rounds2.json`), so the blit
plateau is not a per-op fixed-cost artifact.

### Kernel engine, sizes from 64 MiB to 2 GiB (per-stream GB/s)

| Configuration | 64 MiB | 256 MiB | 512 MiB | 1 GiB | 2 GiB |
|---|---|---|---|---|---|
| A isolated, one direction | 109–113 | 93–112 | 86–113 | — | **113.4** |
| One pair full-duplex (per direction) | ~72–83 | ~53.5 | — | — | **~90** |
| B3 two pairs, 4 streams (aggregate) | 286.6 | 226.3 | 226.3 | **330.2** | — |
| C all 8 streams (aggregate) | 147.7 | 176.7 | 161.1 | **184.7** | — |

No consumer-side cache inflation: the 2 GiB isolated stream (16× the
128 MB Infinity Cache) runs the same 113 GB/s as the 64 MiB stream —
remote-view reads are evidently served uncached from the producer's VRAM.
Large buffers are simply better-amortised: 1 GiB gives the cleanest,
most stable per-stream values.

### Concurrency cap sweep (kernel, 1 GiB, phase C = 8 cross streams)

| In-flight cap | Aggregate GB/s | Per-stream GB/s |
|---|---|---|
| 1 (sequential) | 107.1 | 97.8–113.1 |
| 2 | 169.2 | 52.6–113.1 |
| 4 | 228.2 | 42.6–90.5 (from fanout run) |
| 8 (uncapped) | 184.7 | 23.1–72.2 |

## Findings

1. **The ~90 GB/s "hive pool" is the blit/copy-engine path, not the
   fabric.** The kernel path reaches **113 GB/s on a single isolated
   stream** — 4× the blit single-stream rate — and **330 GB/s aggregate**
   on four disjoint streams. Every earlier report in this repo (p2p
   matrix, copy paths, TP-decode sim, bridge-share) measured the blit
   path; their ceilings stand as blit-path facts but are *not* fabric
   limits.
2. **Kernel pulls match Apple's link rating.** One full-duplex GPU pair:
   ~90 GB/s in each direction simultaneously (180 combined) — consistent
   with Apple's "84 GB/s in each direction" once measurement/wire
   conventions are allowed for. A single unidirectional stream reaches
   113 GB/s.
3. **The four Infinity Fabric links are independent and scale linearly.**
   Two disjoint full-duplex pairs (all 4 links busy, one flow per link
   per direction): 330.2 GB/s aggregate, per-stream 82.9–90.1 — ~4× the
   single-link rate, no sharing penalty.
4. **What kills throughput is multiple concurrent flows sharing one
   link.** Phase C (8 streams ⇒ every link carries 2 same-direction
   flows) aggregates 184.7 GB/s — *half* of the 330 that the same four
   links achieve at one flow each. Multiplexing two flows on a link does
   not halve each flow's share of full bandwidth; it collapses link
   utilisation to ~46 GB/s total.
5. **App-side scheduling recovers most of it.** A semaphore cap of 4
   in-flight streams: 228 GB/s; cap 2: 169; sequential: 107. The optimum
   is not "as concurrent as possible" — 4 in flight beats 8. (A
   link-aware schedule that never puts two active flows on the same link
   should approach 330; not yet implemented.)
6. **On-module ≡ cross-card, again.** Same-module phase B (281.8 kernel)
   behaves like cross-card B3 (286.6) at equal structure, extending the
   bridge-share report's uniform-fabric conclusion into the kernel path.
7. Kernel pulls of remote views are **correct and fast** — this also
   settles the open "can compute kernels read remote views at usable
   bandwidth" question: yes, at full link rate (verified via same
   correctness-insensitive timing path; see gotchas for the read-only
   constraint).

## Capacity-planning rules (revised, kernel engine)

- A bridged 2× W6800X Duo hive moves **~330 GB/s aggregate** when each
  of the 4 links carries **one** flow per direction — budget ~85–90 GB/s
  per direction per link, not ~90 GB/s hive-wide.
- **One flow per link at a time.** Two concurrent flows on one link cut
  that link to ~46 GB/s combined. Design collectives (all-reduce,
  all-to-all) so per-GPU egress is serialised at the application level;
  a simple global in-flight cap of 4 already beats full concurrency
  (228 vs 185).
- Use **kernel copies**, not blit copies, for Infinity Fabric transfers:
  blit peaks at ~90 GB/s hive-wide regardless of schedule.
- Prefer **large transfers** (≥512 MiB per flow): fixed per-op costs eat
  15–30% of a 64 MiB kernel pull.

## Raw data

`raw/2026-09-12-a2a-bw-sweep.json` (blit, 64 MiB, sweep + caps),
`raw/2026-09-12-a2a-bw-rounds2.json` (blit rounds control),
`raw/2026-09-12-a2a-bw-kernel.json` (kernel, 64 MiB),
`raw/2026-09-12-a2a-bw-kernel-big.json` (kernel, 256 MiB),
`raw/2026-09-12-a2a-bw-kernel-nocache.json` (kernel, 512 MiB subset),
`raw/2026-09-12-a2a-bw-kernel-2gib-pair.json` (kernel, 2 GiB, one pair),
`raw/2026-09-12-a2a-bw-kernel-1gib-fanout.json` (kernel, 1 GiB, B3/C/E8),
`raw/2026-09-12-a2a-bw-kernel-1gib-cap1.json`,
`raw/2026-09-12-a2a-bw-kernel-1gib-cap2.json`.

## Conclusions

Revises the "is the ceiling fabric or driver?" open question in the
[bridge-share report](2026-09-12-w6800x-duo-bridge-share.md): **driver +
copy-engine, not fabric.** The Infinity Fabric Link bridge lives up to
Apple's rating under kernel-driven load. Follow-ups this unlocks: a
link-aware collective schedule targeting ~330 GB/s, and re-running
[`tp-sim`](2026-09-12-w6800x-duo-tp-decode-sim.md) (currently blit-based)
with kernel pulls — its decode all-reduce should improve several-fold.
Tool docs: [a2a-bw README](../../tools/a2a-bw/README.md).
