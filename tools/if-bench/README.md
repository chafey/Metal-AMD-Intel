# if-bench

Measures bandwidth and latency across the on-card Infinity Fabric bridge of
Duo MPX cards, with baselines for local VRAM and host PCIe paths.

**Status:** planned (Phase 3). See
[docs/hardware/infinity-fabric.md](../../docs/hardware/infinity-fabric.md) for
the measurement matrix it must cover:

1. host → partition A / host → partition B (PCIe inbound)
2. partition A ↔ partition B (the IF bridge — headline number)
3. partition A ↔ partition A (local baseline)
4. card 1 ↔ card 2 through the host (comparison)

Design notes:

- Sizes: 4 KB → 512 MB sweep; report bandwidth vs. size curves.
- Latency via dependent ping-pong copies; bandwidth via pipelined blits.
- Distinguish copy-engine (blit) vs. kernel-driven copy paths.
- `--mode concurrent-load` doubles as the repro for co-scheduling issues
  tracked in `docs/metal/gotchas.md`.
