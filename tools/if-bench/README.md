# if-bench

Measures bandwidth and latency across the on-module **Infinity Fabric Link
jumper** of Duo MPX cards and the cross-card **Infinity Fabric Link bridge**,
with baselines for local VRAM and host PCIe paths.

**Status:** planned (Phase 3). See
[docs/hardware/infinity-fabric.md](../../docs/hardware/infinity-fabric.md) for
the measurement matrix it must cover:

1. host → partition A / host → partition B (PCIe inbound)
2. partition A ↔ partition B (on-module Infinity Fabric Link jumper —
   headline number)
3. partition A ↔ partition A (local baseline)
4. cross-card over the Infinity Fabric Link bridge (card 1 ↔ card 2 direct
   peer path)
5. cross-card without Infinity Fabric Link bridge, through the host
   (comparison/fallback)

Design notes:

- Sizes: 4 KB → 512 MB sweep; report bandwidth vs. size curves.
- Latency via dependent ping-pong copies; bandwidth via pipelined blits.
- Distinguish copy-engine (blit) vs. kernel-driven copy paths.
- `--mode concurrent-load` doubles as the repro for co-scheduling issues
  tracked in `docs/metal/gotchas.md`.
