# Infinity Fabric on MPX Cards

Infinity Fabric (xGMI) appears in MPX systems at two levels, with distinct
Apple terminology:

- **Infinity Fabric Link jumper** — connects the two GPUs *on one module*
  (Vega II Duo, W6800X Duo).
- **Infinity Fabric Link bridge** — connects GPUs *across two cards*, joining
  them into one xGMI hive.

This document covers both: architecture, measured behavior, and implications
for Metal programs.

## Architecture (overview)

- Each partition is a full GPU with its own VRAM and its own path to the host
  over the module's PCIe uplink.
- The on-module Infinity Fabric **Link jumper** provides GPU-to-GPU peer
  access between the two GPUs of a Duo card without traversing the host root
  complex.
- An **Infinity Fabric Link bridge** can additionally connect GPUs across two
  MPX cards (confirmed pairings: W6800X Duo + W6800X Duo, W6900X + W6900X,
  Vega II + Vega II; cross-card bridging of a Vega II Duo + Vega II Duo pair
  may not be an Apple-supported configuration — see
  [mpx-cards.md](mpx-cards.md)). Both cards then join one xGMI hive with
  direct GPU-to-GPU paths between cards; without a bridge, cross-card traffic
  falls back to the PCIe host path.
- Two Duo cards with an on-module jumper on each but **no bridge** are two
  *independent* 2-GPU IF domains: the jumpers do not connect the cards to
  each other.
- TODO: link widths and generation per hop (on-module jumper vs cross-card
  bridge),
  confirmed from IORegistry captures rather than datasheet guesses.

## Bandwidth and latency

Measured numbers live in [../benchmarks/](../benchmarks/) and are produced by
[`tools/if-bench`](../../tools/if-bench). Summary table (fill in as reports land):

| Card | Direction | Buffer size | Bandwidth | Latency | Report |
|---|---|---|---|---|---|
| W6800X Duo | local (device → own VRAM) | 64 MiB | 70.3–74.3 GB/s | 3.9–4.3 µs/copy @4 KiB | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → staging write (blit hop) | 64 MiB | 24–25 GB/s (kernel hop: 106–192) | — | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | staging → dev read (blit hop) | 64 MiB | 88–106 GB/s | — | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → dev (within one hive, via staging, 2 hops) | 64 MiB/hop | 8.3–8.6 GB/s (blit hops) / 9.7–10.2 GB/s (kernel hops) | 121–148 µs/hop @4 KiB | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → dev (p2p pull, on-module Infinity Fabric Link jumper) | 64 MiB | 36.9–37.0 GB/s (blit) / 35.8–36.2 (kernel read) | 54–61 µs/pull (serialized) | [2026-09-11 p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md) |
| W6800X Duo ×2 | dev → dev (p2p pull, cross-card Infinity Fabric Link bridge) | 64 MiB | 37.6–38.5 GB/s (blit) / 36.9–37.5 (kernel read) | 54–98 µs/pull (serialized) | [2026-09-11 p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md) |

Findings from the 2026-09-11 reports, pending independent confirmation:

- **Metal does expose a direct GPU→GPU path on this driver** via
  peer-group remote buffer views (`MTLDevice.peerGroupID` +
  `MTLBuffer newRemoteBufferViewForDevice:`, public macOS 10.15+ APIs).
  The xGMI hive appears as one Metal peer group; a device whose queue
  **pulls** (reads) a view of the peer's VRAM reaches 36.9–38.5 GB/s with
  no IOSurface staging (jumper and bridge indistinguishable within
  session variance). Views are read-only on AMDRadeonX6000 — the pull
  direction is mandatory ([gotchas](../metal/gotchas.md)). Cross-hive
  pairs (hive member ↔ non-hive card) are not in a peer group and return
  nil views. (An earlier revision of this document claimed no direct
  GPU→GPU copy existed; that was wrong — the claim only ever held for the
  staging route.)
- **The staging route** (IOSurface, two hops, one commit/wait each)
  measures the same for a same-module pair and for the bridged cross-card
  pair (chain plateau 8.3–10.2 GB/s) — no visible bridge benefit *through
  that route*, while p2p pull shows a healthy link under both topologies.
- Staging hop rates (88–106 GB/s blit reads; 106–192 GB/s kernel-driven)
  **exceed the PCIe Gen3 x16 ceiling**,
  so the driver places IOSurface pages in GPU memory rather than host RAM;
  whether remote access rides the xGMI hive is not yet directly evidenced
  for the staging route (for the p2p route, the peer group == xGMI hive
  correspondence is directly evidenced by `peerGroupID` values).

Directions worth distinguishing:

1. Host → partition A (PCIe inbound)
2. Host → partition B
3. Partition A ↔ partition B (on-module Infinity Fabric Link jumper —
   headline
   measurement)
4. Partition A ↔ partition A (local VRAM, the baseline)
5. Cross-card **over the Infinity Fabric Link bridge** (card 1 ↔ card 2
   direct
   peer path)
6. Cross-card **without Infinity Fabric Link bridge** (through the host —
   comparison/fallback)

## Programming model implications

TODO: cover buffer placement, paging behavior when a kernel touches remote
VRAM, explicit peer-copy strategies, and scheduling/co-residency rules across
partitions. See [../metal/tuning.md](../metal/tuning.md).

## Related

- [mpx-cards.md](mpx-cards.md)
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md)
