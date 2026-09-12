# Benchmark Report: 2× W6800X Duo — kernel vs blit ceiling (v2, corrected)

> **This report replaces the same-day v1, which is retracted.** v1's
> kernel-engine results (113 GB/s isolated, 330 GB/s aggregate, "links
> independent") were an artefact: `a2a-bw`'s kernel engine loaded remote
> views with `uchar4` — 16 bytes but only **4-byte aligned** — and
> misaligned 16-byte loads of remote buffer views are served from a
> non-snooped cache: stale data, read at fake local-cache speed. See
> [gotchas](../metal/gotchas.md) and the
> [`remote-view-check`](../../tools/remote-view-check/) regression tool
> (`raw/2026-09-12-remote-view-check.txt` shows `uchar4` at 111–113 GB/s
> with stale mid/tail while every naturally aligned width is correct at
> 22–29 GB/s). v1's blit-engine results were never affected and are kept.

- **Date:** 2026-09-12 (v2, same day, after the alignment-bug discovery)
- **Author:** repo maintainer
- **Tool:** `a2a-bw` v2 with the kernel engine corrected to `uint4`
  (16-byte aligned); `remote-view-check` for the correctness contract
- **Exact commands** (all raw files in `raw/`):
  - `tools/.build/release/a2a-bw --json` → `raw/2026-09-12-a2a-bw-sweep.json` (blit, 64 MiB)
  - `tools/.build/release/a2a-bw --rounds 2 --json` → `raw/2026-09-12-a2a-bw-rounds2.json` (blit control)
  - `tools/.build/release/a2a-bw --engine kernel --json` → `raw/2026-09-12-a2a-bw-kernel-fixed-64mib.json`
  - `tools/.build/release/a2a-bw --engine kernel --bytes 1073741824 --rounds 1 --iters 1 --json`
    → `raw/2026-09-12-a2a-bw-kernel-fixed-1gib.json`
  - `tools/.build/release/remote-view-check` → `raw/2026-09-12-remote-view-check.txt`
  - v1 kernel raw files (`raw/2026-09-12-a2a-bw-kernel*.json` except `*-fixed-*`)
    are retained **as artefacts of the misaligned-load bug**; do not cite them.

## Question

Is the ~90 GB/s aggregate ceiling reported by the
[bridge-share report](2026-09-12-w6800x-duo-bridge-share.md) (measured with
blit copies) a limit of the copy-engine/driver path, or of the fabric
itself? A compute-kernel read path (`--engine kernel`) is a different
submission route to the same peer-group links, so it can discriminate.

## Machine

Mac Pro (MacPro7,1), Xeon W-3245, 2× Radeon Pro W6800X Duo, Infinity
Fabric Link bridge fitted, modules = dies {1,2} | {3,4}, macOS 26.6.2
(25G83), AMDRadeonX6000 7.0.1. The RX 6900 XT display card (dev0) is
never measured.

## Method

Each stream pulls a remote buffer view into the consumer's own VRAM on
the consumer's queue, as either blit copies or full-grid compute
dispatches (one `uint4` — 16-byte aligned — per thread; the earlier
`uchar4` variant is invalid, see banner). Phase schedule identical
across engines. Streams keep any remote buffer at ≤3 concurrent
consumers (driver hang limit). `remote-view-check` establishes the
coherence contract that makes kernel-engine numbers citable: naturally
aligned loads, producer rewrites the source between rounds, results
verified against the fresh pattern.

## Results

### Correctness contract (`remote-view-check`, 1 GiB + 16 MiB, 3 rewrite rounds each)

| Load type | Result | Bandwidth |
|---|---|---|
| `uint` (4 B), `ulong` (8 B), `ulong2` (16 B, 16-aligned) | **correct** at every probe (1 GiB head/mid/tail spot, 16 MiB full-CPU verify), all rounds | 22.8–29.4 GB/s |
| `uchar4` (16 B, 4-byte aligned) | **stale beyond an initial window**, unchanged by producer rewrites that have completed | 111–113 GB/s (bogus — cache artefact) |

### Head-to-head, same phase schedule (64 MiB streams, aggregate GB/s)

| Phase | Blit | Kernel (corrected) |
|---|---|---|
| A isolated (per stream) | 27.4–29.6 | 27.3–29.5 |
| B same-module pairs, 4 streams | 90.1 | 92.6 |
| B2 one pair full-duplex, 2 streams | 45.1 | 45.9 |
| B3 two disjoint pairs, 4 streams | 90.5 | 92.9 |
| C all 8 cross streams | 50.8 | 85.1 |
| E3/E5/E6 cross sweeps | — | 75.1 / 105.2 / 108.3 |
| E8 with semaphore cap 4 | 66.0 | 134.8 |
| D all-to-all, 12 streams | 62.7 | 114.8 |

1 GiB streams (kernel): A = 28.1–29.4 per stream, B = 96.1, B2 = 48.0,
B3 = 95.8, C = 73.6, E8cap4 = 142.0, D = 110.0.

## Findings

1. **Kernel pulls and blit pulls have the same per-flow ceiling:
   ~24–29 GB/s.** The corrected kernel engine reproduces the blit
   schedule-level behaviour almost exactly at ≤4 streams on disjoint
   pairs. There is no "fast kernel path" beyond the copy engine; v1's
   apparent 4× advantage was entirely the alignment bug.
2. **Disjoint GPU pairs do NOT share capacity.** One full-duplex pair
   alone gets 45.9 GB/s aggregate (B2); two disjoint pairs concurrently
   get 92.9 (B3) — exactly 2×, no sharing penalty. So the "hive-wide
   ~90 GB/s pool" framing from earlier reports is wrong as a *capacity*
   statement: ~90 GB/s is what 4 links × one ~24 GB/s blit flow happens
   to sum to. Aggregate keeps rising with more streams (kernel D = 110–115).
3. **No single flow comes close to the 84 GB/s link rating** on either
   path: 24 (blit) / 29 (kernel) GB/s per flow. The limit at one flow
   per link is the submitting path, not the link.
4. **What collapses throughput is multiple concurrent flows on one
   link** (phase C: 8 cross streams = 2 per link ⇒ 50.8 blit / 73.6–85.1
   kernel, versus ~93 at 4 flows on 4 links) and **≥5 simultaneous
   consumers of the fabric generally** (unfair, unstable shares; driver
   scheduling, matches the bridge-share report).
5. **App-side throttling helps the kernel engine** (E8: 85–142 GB/s
   aggregate with a cap of 4 in flight, vs 50.8 blit uncapped) but the
   per-stream floor is still ~6–11 GB/s for the losers.
6. **On-module ≡ cross-card continues.** Same-module pairs (B, on-module
   Link jumpers) and cross-card pairs (B3, via the Link bridge) aggregate
   identically at equal structure, individually and mixed. This is
   consistent both with all P2P traffic traversing the bridge adapter and
   with a separate onboard path — no measurement in this repo
   distinguishes them; capacity plans don't need to.

## Capacity-planning rules (v2)

- Budget **~24 GB/s per blit flow, ~29 GB/s per kernel flow**, one flow
  per GPU pair at a time; ~90 GB/s hive aggregate is the natural sum of
  4 links × one flow, and 2 disjoint pairs do scale to 2× (no shared pool).
- **One flow per pair-link at a time**: a second concurrent flow on the
  same link collapses that link's aggregate below a single flow.
- Kernel reads of remote views must use **naturally aligned load types**
  and be validated with `remote-view-check` when the kernel changes;
  blit copies have no such constraint.
- Apple's 84 GB/s per direction is a per-link hardware rating never
  reached by any software path measured here.

## Raw data

`raw/2026-09-12-a2a-bw-sweep.json`, `raw/2026-09-12-a2a-bw-rounds2.json`
(blit, unaffected by the bug), `raw/2026-09-12-a2a-bw-kernel-fixed-64mib.json`,
`raw/2026-09-12-a2a-bw-kernel-fixed-1gib.json` (corrected kernel engine),
`raw/2026-09-12-remote-view-check.txt` (coherence contract, includes the
intentional `uchar4` failure row). v1 kernel raw files retained as bug
artefacts, labelled in `raw/README.md`.

## Conclusions

The ~90 GB/s figure that appears across every report in this repo is not
a fabric capacity and not a copy-engine limit: it is the arithmetic sum
of four links each carrying one ~24 GB/s blit flow. The fabric's per-link
rating (84 GB/s/direction) is never approached by any measured software
path; the per-flow ceiling (24 blit / 29 kernel) and the same-link
multiplexing collapse are the facts that should drive collective design.
For tensor-parallel decode specifically,
[`tp-sim`](2026-09-12-w6800x-duo-tp-decode-sim.md) remains the relevant
measurement — its 32 KiB all-reduces are latency-bound, so the per-flow
bandwidth story changes nothing there.
