# Infinity Fabric on MPX Cards

Infinity Fabric (xGMI) links appear in MPX systems at two levels: **on-card**
(the two partitions of a Duo card — Vega II Duo, W6800X Duo — are joined by a
module-internal bridge) and **cross-card** (an external IF bridge connects two
MPX cards into one xGMI hive). This document covers the links' architecture,
measured behavior, and implications for Metal programs.

## Architecture (overview)

- Each partition is a full GPU with its own VRAM and its own path to the host
  over the module's PCIe uplink.
- The on-card IF bridge provides GPU-to-GPU peer access between the two
  partitions without traversing the host root complex.
- A **cross-card Infinity Fabric link** can additionally connect two MPX
  cards, offered as two interconnect options: a **link jumper** and a
  **link bridge** (confirmed pairings for at least one option: W6800X Duo +
  W6800X Duo, W6900X + W6900X, Vega II + Vega II; the Vega II Duo + Vega II
  Duo pairing may not be an Apple-supported configuration — see
  [mpx-cards.md](mpx-cards.md)). Both
  cards then join one xGMI hive with direct
  GPU-to-GPU paths between cards; without a cross-card link, cross-card
  traffic falls back to the PCIe host path.
- Evidence: a linked 2× W6800X Duo system shows a single hive of 4 nodes
  (`XGMI_HiveSize = 4`, `XGMI_NodeIndex` 0–3) in IORegistry — see
  [mpx-cards.md](mpx-cards.md#evidence-2-w6800x-duo-cross-card-linked).
- TODO: link widths and generation per hop (intra-card vs cross-card bridge),
  confirmed from IORegistry captures rather than datasheet guesses.

## Bandwidth and latency

Measured numbers live in [../benchmarks/](../benchmarks/) and are produced by
[`tools/if-bench`](../../tools/if-bench). Summary table (fill in as reports land):

| Card | Direction | Buffer size | Bandwidth | Latency | Report |
|---|---|---|---|---|---|
| _none yet_ | | | | | |

Directions worth distinguishing:

1. Host → partition A (PCIe inbound)
2. Host → partition B
3. Partition A ↔ partition B (on-card IF bridge — headline measurement)
4. Partition A ↔ partition A (local VRAM, the baseline)
5. Cross-card **over the IF link** (card 1 ↔ card 2 direct peer path) —
   measure separately with the link jumper and the link bridge fitted
6. Cross-card **without cross-card link** (through the host — comparison/fallback)

## Programming model implications

TODO: cover buffer placement, paging behavior when a kernel touches remote
VRAM, explicit peer-copy strategies, and scheduling/co-residency rules across
partitions. See [../metal/tuning.md](../metal/tuning.md).

## Related

- [mpx-cards.md](mpx-cards.md)
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md)
