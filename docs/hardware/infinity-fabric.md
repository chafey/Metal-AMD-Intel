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
  Measured behaviour: with **kernel-driven** pulls the bridge reaches
  Apple's rating (~90 GB/s per direction on one full-duplex pair, 330
  GB/s aggregate across four independent links); with **blit** copies the
  whole hive plateaus at ~90 GB/s regardless of schedule. See the
  [kernel-vs-blit ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).
- **Vega II / Vega II Duo:** 84 GB/s stated *without* the "in each direction"
  qualifier (direction convention unstated).

Reading these numbers: 84 GB/s per direction is a rating for **one
physical link** — a link capacity, not a per-GPU-pair reservation. What
the measurements show on a bridged 2× W6800X Duo hive (2026-09-12,
[kernel-vs-blit ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)):
under **kernel-driven** load the four links behave independently and the
fabric lives up to the rating (~90 GB/s per direction per full-duplex
pair; 330 GB/s with four disjoint flows); under **blit** load the driver
never gets past ~90 GB/s hive-wide. Whether on-module traffic physically
traverses the bridge adapter or an onboard link is still **not exposed by
the IORegistry and not distinguishable by any measurement in this repo**
(both paths perform identically); capacity planning should budget each
GPU's link independently — but see the link-sharing caveat in the
ceiling report before running concurrent flows.

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

Concurrent bulk flows (`a2a-bw`, 64 MiB streams unless noted; medians):

| Engine | Configuration | Bandwidth | Report |
|---|---|---|---|
| blit | 4 cross-card streams (2 disjoint pairs) | aggregate 90.5–90.7; per-stream 22.7–24.4 — identical to the same-module 4-stream control | [bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) |
| blit | 8 cross-card streams | aggregate 50.7–55.2; per-stream 6.4–18.8 (unfair, unstable) | [bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) |
| blit | same-module pairs, both simultaneously (4 streams) | aggregate 90.3–96.1 — **no better than cross-card at equal structure** | [bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) |
| kernel | 1 stream isolated (2 GiB) | 113.4 GB/s — 4× the blit single-stream rate | [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel | 1 full-duplex pair (2 GiB) | ~90 per direction (≈180 combined) — matches Apple's rating | [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel | 4 disjoint streams, all 4 links (1 GiB) | aggregate 330.2; per-stream 82.9–90.1 — links are independent | [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel | 8 cross-card streams (2 per link, 1 GiB) | aggregate 184.7 — flows sharing a link collapse it to ~46 GB/s | [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel | same 8, semaphore cap 4 in flight | aggregate 228.2 (cap 2: 169.2; sequential: 107.1) | [ceiling](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |

**Final model (2026-09-12): the ~90 GB/s ceiling is the copy engine, not
the fabric.** Kernel-driven remote reads reach Apple's rated link speed
(~84–90 GB/s per direction) and the four Infinity Fabric links scale
independently (330 GB/s aggregate). The blit/copy-engine path plateaus at
~90 GB/s hive-wide under any schedule. Two flow-level caveats apply to
both engines: two concurrent flows sharing one link collapse that link to
~46 GB/s combined (serialise per-link egress at the app level), and
earlier claims that the on-module Infinity Fabric Link jumper provides
independent, additive capacity were a stream-count artifact — at equal
structure, on-module and cross-card flows perform identically. Note the
kernel bandwidth depends on the read kernel's parallelism:
`if-bench`'s simpler kernel-read mode measured only ~36 GB/s single-stream
where `a2a-bw`'s `uchar4` grid-stride reaches 113. See
[the ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).

Directions worth distinguishing — status on the 2× W6800X Duo + bridge
reference configuration (numbers and method in the linked reports):

| # | Direction | Status | Where |
|---|---|---|---|
| 1 | Host → partition (PCIe inbound) | measured | [copy-paths report](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md) |
| 2 | Partition → host (PCIe outbound) | measured | same report |
| 3 | On-module GPU ↔ GPU (Infinity Fabric Link jumper) | measured | [p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md) (isolated) + [bridge-share](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md) (concurrent) |
| 4 | GPU ↔ own VRAM (local baseline) | measured | copy-paths report |
| 5 | Cross-card over the Infinity Fabric Link bridge | measured | same as #3 — performs identically to on-module at equal concurrency |
| 6 | Cross-card **without** bridge | no peer group forms, so no p2p route exists to measure; the practical fallback is the IOSurface staging route, measured in the copy-paths report | copy-paths report |

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
