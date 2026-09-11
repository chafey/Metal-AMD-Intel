# Infinity Fabric on MPX Duo Cards

The Duo MPX cards (Vega II Duo, W6800X Duo) contain two GPU partitions joined
by an on-card **Infinity Fabric** bridge (an xGMI link). This document covers
the link's architecture, measured behavior, and implications for Metal
programs.

## Architecture (overview)

- Each partition is a full GPU with its own VRAM and its own path to the host
  over the module's PCIe uplink.
- The IF bridge provides GPU-to-GPU peer access between the two partitions
  without traversing the host root complex.
- TODO: link widths and generation per card (Vega II Duo vs W6800X Duo),
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
3. Partition A ↔ partition B (the IF bridge — the headline measurement)
4. Partition A ↔ partition A (local VRAM, the baseline)
5. Cross-card: card 1 ↔ card 2 through the host (for comparison)

## Programming model implications

TODO: cover buffer placement, paging behavior when a kernel touches remote
VRAM, explicit peer-copy strategies, and scheduling/co-residency rules across
partitions. See [../metal/tuning.md](../metal/tuning.md).

## Related

- [mpx-cards.md](mpx-cards.md)
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md)
