# AMD MPX Cards

Module eXpansion (MPX) cards are Apple/AMD co-designed GPU modules for the
Intel Mac Pro (2019) and, for the Vega family, the iMac Pro. This page is the
reference matrix; per-card deep dives link from each row.

## Matrix

| Card | Silicon | CUs | VRAM | Bandwidth | TDP | Hosts | xGMI hive | Notes |
|---|---|---|---|---|---|---|---|---|
| Radeon Pro Vega II | Vega 20 (1 die) | 64 | 32 GB HBM2 | 1 TB/s | ~300 W | iMac Pro, Mac Pro (2019) | – | First 7 nm GPU; IOX (I/O hub) die on package |
| Radeon Pro Vega II Duo | 2× Vega 20 | 2× 64 | 2× 32 GB HBM2 | 1 TB/s per die | ~500 W | iMac Pro, Mac Pro (2019) | 1 hive × 2 nodes | Two dies joined by an Infinity Fabric Link jumper |
| Radeon Pro W5700X | Navi 10 (RDNA 1) | 40 | 16 GB GDDR6 | 448 GB/s | ~205 W | Mac Pro (2019) | – | Single wide slot |
| Radeon Pro W6800X | Navi 21 (RDNA 2) | 56 | 32 GB GDDR6 | 512 GB/s | ~200 W | Mac Pro (2019) | – | Single wide slot |
| Radeon Pro W6800X Duo | 2× Navi 21 | 2× 56 | 2× 32 GB GDDR6 | 512 GB/s per die | ~300 W | Mac Pro (2019) | 1 hive × 2 nodes | Two partitions joined by an Infinity Fabric Link jumper |
| Radeon Pro W6900X | Navi 21 (RDNA 2) | 56 | 32 GB GDDR6 | 512 GB/s | ~190 W | Mac Pro (2019) | – | Highest-bin single W6800X-class part |

> TODO: verify CU counts/TDPs/memory bandwidth against Apple spec sheets and
> cite sources; add per-card IOKit `device-id` / `revision-id` table once
> captured with [`tools/gpu-probe`](../../tools/gpu-probe).

## Duo cards and the Infinity Fabric Link jumper

Per Apple's terminology, an **Infinity Fabric Link jumper** connects the two
GPUs on one module; an **Infinity Fabric Link bridge** connects GPUs across
two cards (see [Multi-card configurations](#multi-card-configurations)).

The Duo cards expose **two GPU partitions on one physical module**:

- **Vega II Duo:** two full Vega 20 dies linked by on-module xGMI (Infinity
  Fabric); each die has its own 32 GB HBM2.
- **W6800X Duo:** two Navi 21 partitions connected by an Infinity Fabric
  Link jumper, each with its own 32 GB GDDR6.

How Duo modules appear to the OS is documented in
[../metal/gpu-exposure.md](../metal/gpu-exposure.md): a `gpu-probe` capture
of a 2× W6800X Duo system (2026-09-11) showed one `MTLDevice` and one
`IOPCIDevice` function (`GFX0`) per die — four each — all reporting
`XGMI_HiveSize = 4` with `XGMI_NodeIndex` 0…3.

## Multi-card configurations

Mac Pro (2019) supports multiple MPX modules, and an **Infinity Fabric Link
bridge** can connect GPUs across two of them into a single xGMI hive, giving
direct GPU-to-GPU paths between cards that bypass the host. (The **Infinity
Fabric Link jumper** is the separate on-module connector joining a Duo card's
two GPUs; it is not a cross-card option.)

| Configuration | GPU silicon | VRAM | Bandwidth | Infinity Fabric | xGMI hive |
|---|---|---|---|---|---|
| 2× W6800X Duo, Link jumpers only | 4× Navi 21 | 4× 32 GB GDDR6 (128 GB) | 512 GB/s per GPU | cards **not** IF connected; jumper joins GPUs within each module | 2 hives × 2 nodes |
| 2× W6800X Duo, Link bridge | 4× Navi 21 | 4× 32 GB GDDR6 (128 GB) | 512 GB/s per GPU | bridge joins the two module hives | 1 hive × 4 nodes |
| 2× W6900X, Link bridge | 2× Navi 21 | 2× 32 GB GDDR6 (64 GB) | 512 GB/s per GPU | supported | 1 hive × 2 nodes |
| 2× Vega II, Link bridge | 2× Vega 20 | 2× 32 GB HBM2 (64 GB) | 1 TB/s per GPU | supported | 1 hive × 2 nodes |
| 2× Vega II Duo, Link jumpers only | 4× Vega 20 | 4× 32 GB HBM2 (128 GB) | 1 TB/s per GPU | cards **not** IF connected; jumper joins GPUs within each module | 2 hives × 2 nodes |
| 2× Vega II Duo, Link bridge | 4× Vega 20 | 4× 32 GB HBM2 (128 GB) | 1 TB/s per GPU | ⚠️ may not be an Apple-supported configuration | 1 hive × 4 nodes (unverified) |

IF link capacity per Apple: the W6800X / W6900X Infinity Fabric Link connects
two GPUs "at up to 84GB/s in each direction", and the W6800X Duo's onboard
(jumper) link likewise; Apple gives **no bandwidth figure for the external
(bridge) connection**, only that it links four GPUs
([tech specs](https://support.apple.com/en-ge/118461); link-capacity vs
per-flow semantics discussed in
[infinity-fabric.md](infinity-fabric.md)).

Note for Duo cards: each module's on-module **Infinity Fabric Link jumper**
makes its two GPUs one IF domain regardless of any bridge. Two Duo cards with
jumpers but no bridge are therefore **two independent 2-GPU IF domains**; the
cards are not Infinity Fabric connected to each other.

Open questions (capture with `iokit-dump`, measure with `if-bench`):

- Infinity Fabric Link jumper vs bridge: exact hardware/part numbers, how
  each attaches (on-module vs across modules), and the official supported-
  pairings list per Apple
- Confirmed cross-card pairings so far: W6800X Duo, W6900X, Vega II
  (verify others; see next bullet for the Vega II Duo pairing)
- **Support status of 2× Vega II Duo joined by an Infinity Fabric Link
  bridge:** two Duo modules with their on-module jumpers operate as
  independent cards (not Infinity Fabric connected). Whether the pair may
  additionally be joined across cards with an Infinity Fabric Link bridge may
  not be a configuration Apple supports (physically/technically achievable
  vs. officially supported are separate questions). Find and cite Apple's Mac
  Pro/MPX configuration matrix, and note results of an `ioreg` check on a
  real bridge-linked Vega II Duo pair (does the hive form with
  `XGMI_HiveSize = 4`, or does the driver refuse to bridge the cards?)
- TODO: capture `ioreg` output from a 2× Vega II Duo system (on-module
  jumpers fitted, no bridge) to document the unbridged hive shape — expected
  two independent hives of 2 (`XGMI_HiveSize = 2` each), to be confirmed
- Link widths per hop (on-module Infinity Fabric Link jumper vs cross-card
  Infinity Fabric Link bridge) and whether they differ — **settled as far as
  macOS allows** (2026-09-12): a full IORegistry capture
  ([raw extract](raw/2026-09-12-ioreg-xgmi.txt),
  [findings](infinity-fabric.md#architecture-overview)) exposes **no**
  per-link width/generation keys — the driver publishes hive membership
  only (`XGMI_HiveID/HiveSize/NodeID/NodeIndex` + `InfinityFabricLinks`).
  This cannot be settled from the registry; only datasheets or Apple
  documentation could, and neither is public — measured per-flow rates are
  the ground truth
- Bandwidth/latency of the cross-card IF hop vs intra-card hop vs the
  host path: **measured**. On peer pulls, cross-card ≈ on-module
  (single-stream ~27–30 GB/s either way,
  [p2p matrix](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md);
  hive-pool behaviour under concurrency in the
  [bridge-share report](../benchmarks/2026-09-12-w6800x-duo-bridge-share.md)).
  Without a bridge no peer group forms, so the practical fallback is the
  IOSurface staging route — measured in the
  [copy-paths report](../benchmarks/2026-09-11-w6800x-duo-copy-paths.md).
- Per-slot constraints: which slot pairs the bridge supports, and per-CPU
  attachment on dual-socket parts (see [host-machines.md](host-machines.md))

Resolved: the 2× W6800X Duo capture machine (2026-09-11, source of the
`XGMI_HiveSize = 4` observation) has an **Infinity Fabric Link bridge
fitted**, consistent with the "1 hive × 4 nodes" bridge row in the table
above. The unbridged jumpers-only hive shape (expected 2 hives × 2 nodes)
is still uncaptured — see the Vega II Duo bullet above.

## Related

- [infinity-fabric.md](infinity-fabric.md) — link architecture and bandwidth
- [host-machines.md](host-machines.md) — slots and electrical topology
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md) — how Metal sees these cards
