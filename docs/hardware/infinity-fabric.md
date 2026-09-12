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
  Measured behaviour: no software path measured in this repo — neither
  **blit** copies nor **kernel-driven** pulls — exceeds ~29 GB/s on a
  single flow; four simultaneous flows on disjoint GPU pairs sum to
  ~90–96 GB/s. A same-day early claim that kernel pulls reach Apple's
  rating (330 GB/s aggregate) was retracted: it was misaligned
  (`uchar4`) loads of remote views returning stale cached data at fake
  speed. See the corrected
  [kernel-vs-blit ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).
- **Vega II / Vega II Duo:** 84 GB/s stated *without* the "in each direction"
  qualifier (direction convention unstated).

Reading these numbers: 84 GB/s per direction is a rating for **one
physical link** — a link capacity, not a per-GPU-pair reservation, and
not (by itself) an answer about whether concurrent GPU pairs share it.
What the measurements show on a bridged 2× W6800X Duo hive (2026-09-12,
corrected [ceiling report](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md)):

- **Software never reaches the rated speed on a single flow**: ~24 GB/s
  (blit) / ~29 GB/s (kernel) per flow is the observed ceiling, far below
  84. The limit is the submitting path, not the link.
- **Disjoint GPU pairs do not share capacity**: one full-duplex pair gets
  ~46–48 GB/s alone and the same per-pair rate when a second disjoint
  pair runs concurrently (2×45.9 ≈ 92.9). The familiar "~90 GB/s hive
  ceiling" is the arithmetic sum of four links × one flow, not a shared
  90 GB/s pipe.
- **Two concurrent flows on the *same* link collapse** that link below a
  single flow's rate, and ≥5 simultaneous fabric consumers get unfair,
  unstable shares (driver scheduling).

Whether on-module traffic physically traverses the bridge adapter or an
onboard link is **not exposed by the IORegistry and not distinguishable
by any measurement in this repo** (both paths perform identically under
every schedule tested); capacity planning does not need to distinguish
them, but note that measurements are consistent with the bridge adapter
carrying all P2P traffic, including between two GPUs on one module.

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
| kernel¹ | 1 stream isolated | 27.3–29.5 — indistinguishable from blit | [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel¹ | 1 full-duplex pair | 45.9 (64 MiB) / 48.0 (1 GiB); per-stream 22–24 | [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel¹ | 2 disjoint pairs, 4 streams | 92.9 (64 MiB) / 95.8 (1 GiB) — per-pair rate unchanged vs alone: **pairs do not share capacity** | [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel¹ | 8 cross-card streams (2 per link) | 85.1 (64 MiB) / 73.6 (1 GiB) — same-link flows collapse below 4 one-per-link flows | [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |
| kernel¹ | same 8, semaphore cap 4 in flight | 134.8 (64 MiB) / 142.0 (1 GiB); unfair shares persist | [ceiling v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) |

¹ Corrected kernel engine (`uint4`, 16-byte aligned). The original
2026-09-12 kernel table (113 GB/s isolated, 330.2 aggregate, "links
independent") is **retracted**: it measured misaligned `uchar4` loads
serving stale data from cache. `remote-view-check` guards the contract.

**Final model (2026-09-12, corrected).** The per-**flow** ceiling is
~24 GB/s (blit) / ~29 GB/s (kernel, aligned loads) — kernel reads are
*not* a faster path; the one-flow limit is the submission path, not the
fabric. Disjoint GPU pairs scale additively (no shared hive pool: the
recurring "~90 GB/s" is 4 links × one ~24 GB/s flow). Two concurrent
flows sharing one link collapse below a single flow (serialise per-link
egress at the app level), and ≥5 simultaneous consumers get unstable
shares. Earlier claims — on-module jumpers as independent additive
capacity, and kernel reads reaching rated link speed — are both
retracted (stream-count artifact and misaligned-load artifact
respectively; `if-bench`'s ~36 GB/s `uint4` kernel-read number was valid
all along and agrees with the corrected 27–29 GB/s). See
[the ceiling report v2](../benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md).

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
