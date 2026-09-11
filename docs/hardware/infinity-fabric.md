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
| W6800X Duo | local (device → own VRAM) | 64 MiB | 67 GB/s | 6 µs/copy @1 MiB | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → staging write | 16–64 MiB | 22–26 GB/s | — | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | staging → dev read | 32–64 MiB | 79–101 GB/s | — | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → dev (via staging, 2 hops) | 64 MiB/hop | 7.3–8.8 GB/s | 170–223 µs/hop | [2026-09-11](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| W6800X Duo ×2 | dev → dev (via staging, 2 hops) | 128–256 MiB/hop | ≈ 9.1 GB/s (blit hops) / ≈ 11 GB/s (kernel hops) | — | [2026-09-11 matrix](../benchmarks/2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md) |

Two findings from that report, pending independent confirmation:

- Metal exposes **no direct GPU→GPU copy**; cross-device movement goes
  through an IOSurface staging region (two hops, one commit/wait each), and
  the staging route measures the same for a same-module pair and for the
  bridged cross-card pair — no visible bridge benefit through this API.
- Staging hop rates (up to 101 GB/s) **exceed the PCIe Gen3 x16 ceiling**,
  so the driver places IOSurface pages in GPU memory rather than host RAM;
  whether remote access rides the xGMI hive is not yet directly evidenced.

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
