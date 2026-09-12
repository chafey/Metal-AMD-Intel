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
- Apple rates the W6x-series IF link at 84 GB/s per direction
  ([tech specs](https://support.apple.com/en-ge/118461)), but gives no
  figure for the external bridge connection on Duo modules. TODO: link
  widths and generation per hop (on-module jumper vs cross-card bridge),
  confirmed from IORegistry captures rather than datasheet guesses.

## Bandwidth and latency

### Apple-stated link capacity

Per [Apple's Mac Pro (2019) technical specifications](https://support.apple.com/en-ge/118461):

- **W6800X / W6900X:** "Infinity Fabric Link connection enables two
  [card] GPUs to connect at up to **84 GB/s in each direction**".
- **W6800X Duo:** the **onboard** (jumper) link "connects two W6800X GPUs at
  up to 84 GB/s in each direction"; for the **external** (bridge) connection
  Apple says only that it "enables two W6800X Duo modules to connect four
  W6800X GPUs" — **no bandwidth figure is stated for the bridge link**.
  Measured behavior of the loaded bridge (~85–89 GB/s combined, shared,
  not 84/direction) is in the
  [2026-09-12 bridge-share report](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
- **Vega II / Vega II Duo:** 84 GB/s stated *without* the "in each direction"
  qualifier (direction convention unstated).

Reading these numbers: 84 GB/s per direction is the capacity of **one
physical link**, shared by every flow whose path traverses it — it is a
link rating, not a per-GPU-pair reservation. Inside a Duo (jumper, exactly
two GPUs on one link) the distinction is moot; across a bridge, whether
Apple's 84 GB/s applies and how it divides among flows crossing the single
external connection per module is **not documented by Apple and not yet
measured** — see the open question below the findings.

### Measured

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

| W6800X Duo ×2 | cross-card bulk, 8 streams simultaneously | 64 MiB × 8/stream | aggregate 50.7–54.0 GB/s shared; per-stream 6.4–18.8 | — | [2026-09-12 bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) |
| W6800X Duo ×2 | on-module jumper, both pairs simultaneously | 64 MiB × 8/stream | additive: aggregate 90.3–96.1 GB/s, per-stream 22.6–23.7 | — | [2026-09-12 bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) |

**Bridge bandwidth IS shared (answered 2026-09-12, `a2a-bw`).** Simultaneous
cross-card streams share one link: eight bulk cross-card streams total
~51–54 GB/s aggregate while an isolated single stream runs ~29 GB/s, and
loaded both ways the directions sum to ~85–89 GB/s *combined* — not 84 GB/s
**per direction**. The direction split is consistently asymmetric (module A
consumers get ~1.3× module B consumers') and per-stream arbitration is
unfair (up to 3× spread). By contrast, simultaneous transfers on the two
independent **on-module jumpers** stay additive (~90–96 GB/s aggregate) and
are unaffected by bridge saturation: the jumper and the bridge are
separately-switched capacity. Capacity planning: budget the bridge as
~50 GB/s per direction **shared by all cross-card flows** — see
[the bridge-share report](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md).
This does **not** contradict the small-op findings in
[`tp-sim`/`pull-contention`](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md):
there the cost was driver-side scheduling latency far below any bandwidth
limit; here flows are bulk and hit the physical link.

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

Measured on 2× W6800X Duo (AMDRadeonX6000 7.0.1), via `tp-sim` /
`pull-contention` — see
[the TP-decode simulation report](../benchmarks/2026-09-12-w6800x-duo-tp-decode-sim.md):

- **Remote views are read-only on the consumer side.** Using a
  `newRemoteBufferViewForDevice:` buffer as a blit *destination* aborts
  in the driver; reads (kernel loads or blit-copy *source*) work. The
  supported all-reduce idiom is therefore destination-side pull: copy
  each peer's buffer through a view into local VRAM, sum locally.
- **The driver penalises concurrent remote-view pulls.** Isolated pulls
  cost ~56 µs and multi-source pulls are cheap when only one GPU pulls,
  but with every hive member pulling simultaneously the cost inflates to
  ~100–340 µs *per in-flight remote op* (12 concurrent ops: 4.0 ms vs
  0.54 ms done sequentially). Multi-GPU sync patterns should *serialise*
  the pull phase across ranks rather than maximise concurrency.
- **Four or more consumers of the same remote buffer hang the driver**
  (three are safe; the hanging case needs a process kill, GPUs recover).
- **Keep remote-view command buffers committed promptly.** Thousands of
  *uncommitted* remote-view CBs across the hive wedge the driver; encode
  and commit per operation phase, as real inference engines already do.
- **MTLSharedEvent chains work cross-device on this driver** (verified
  with a correctness gate where every rank's summed result must match),
  so GPU-side sync is viable; signal values must increase
  monotonically.
- Buffer placement and paging behaviour details (remote pages under
  memory pressure, co-residency rules) remain TODO; see
  [../metal/tuning.md](../metal/tuning.md).

## Related

- [mpx-cards.md](mpx-cards.md)
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md)
