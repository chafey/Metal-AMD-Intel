# AMD MPX Cards

Module eXpansion (MPX) cards are Apple/AMD co-designed GPU modules for the
Intel Mac Pro (2019) and, for the Vega family, the iMac Pro. This page is the
reference matrix; per-card deep dives link from each row.

## Matrix

| Card | Silicon | CUs | VRAM | TDP | Hosts | Notes |
|---|---|---|---|---|---|---|
| Radeon Pro Vega II | Vega 20 (1 die) | 64 | 32 GB HBM2 | ~300 W | iMac Pro, Mac Pro (2019) | First 7 nm GPU; IOX (I/O hub) die on package |
| Radeon Pro Vega II Duo | 2× Vega 20 | 2× 64 | 2× 32 GB HBM2 | ~500 W | iMac Pro, Mac Pro (2019) | Two dies joined by Infinity Fabric on-module link |
| Radeon Pro W5700X | Navi 10 (RDNA 1) | 40 | 16 GB GDDR6 | ~205 W | Mac Pro (2019) | Single wide slot |
| Radeon Pro W6800X | Navi 21 (RDNA 2) | 56 | 32 GB GDDR6 | ~200 W | Mac Pro (2019) | Single wide slot |
| Radeon Pro W6800X Duo | 2× Navi 21 | 2× 56 | 2× 32 GB GDDR6 | ~300 W | Mac Pro (2019) | Two partitions joined by an on-card Infinity Fabric bridge |
| Radeon Pro W6900X | Navi 21 (RDNA 2) | 56 | 32 GB GDDR6 | ~190 W | Mac Pro (2019) | Highest-bin single W6800X-class part |

> TODO: verify CU counts/TDPs against Apple spec sheets and cite sources; add
> per-card IOKit `device-id` / `revision-id` table once captured with
> [`tools/gpu-probe`](../../tools/gpu-probe).

## Duo cards and the Infinity Fabric bridge

The Duo cards expose **two GPU partitions on one physical module**:

- **Vega II Duo:** two full Vega 20 dies linked by on-module xGMI (Infinity
  Fabric); each die has its own 32 GB HBM2.
- **W6800X Duo:** two Navi 21 partitions connected by an on-card Infinity
  Fabric bridge, each with its own 32 GB GDDR6.

TODO: document exactly how each appears in IORegistry (one vs. two
`IOPCIDevice`s, one vs. two `MTLDevice`s) — capture and paste real
`gpu-probe` / `iokit-dump` output here.

## Multi-card configurations

Mac Pro (2019) supports multiple MPX modules, and a cross-card **Infinity
Fabric link** can connect two of them into a single xGMI hive, giving direct
GPU-to-GPU paths between cards that bypass the host. Two link options exist:
a **link jumper** and a **link bridge**.

| Configuration | Cross-card link | Partitions | Infinity Fabric topology |
|---|---|---|---|
| 2× W6800X Duo | link jumper | 4× Navi 21 | on-card bridges within each Duo **plus** cross-card jumper; TODO: confirm hive formation and bandwidth vs bridge |
| 2× W6800X Duo | link bridge | 4× Navi 21 | on-card bridges within each Duo **plus** cross-card bridge → one 4-node hive |
| 2× W6900X | link jumper | 2× Navi 21 | cross-card jumper; TODO: confirm hive formation and bandwidth vs bridge |
| 2× W6900X | link bridge | 2× Navi 21 | cross-card bridge |
| 2× Vega II | link jumper | 2× Vega 20 | cross-card jumper; TODO: confirm hive formation and bandwidth vs bridge |
| 2× Vega II | link bridge | 2× Vega 20 | cross-card bridge |
| 2× Vega II Duo | link jumper | 4× Vega 20 | on-card bridges within each Duo **plus** cross-card jumper — ⚠️ may not be an Apple-supported configuration |
| 2× Vega II Duo | link bridge | 4× Vega 20 | on-card bridges within each Duo **plus** cross-card bridge — ⚠️ may not be an Apple-supported configuration |
| Same cards, no cross-card link | – | – | cross-card traffic falls back to the PCIe host path |

### Evidence (2× W6800X Duo, cross-card linked)

Captured from IORegistry on MacPro7,1 / macOS 26.6.2 (25G83), 2026-09-11.
The link jumper vs bridge used at capture time was not recorded (TODO: re-check
on site):

- `InfinityFabricLinks = Yes`, `XGMI_Enabled = Yes` on 4 `IOPCIDevice` nodes
- All 4 nodes share one `XGMI_HiveID` with `XGMI_HiveSize = 4`
- `XGMI_NodeIndex` values 0–3, two nodes under each physical card
- `XGMI_SGPU_FB = No` on all nodes; per-node opaque `XGMI_NodeID` blobs

=> The xGMI hive spans **both physical cards**, confirming a working
cross-card Infinity Fabric link; the four Metal devices enumerated as
"AMD Radeon PRO W6800X Duo" are the four hive partitions (nodes 0–3).

Open questions (capture with `iokit-dump`, measure with `if-bench`):

- Link jumper vs link bridge: exact hardware/part numbers, the physical and
  electrical differences, per-option supported pairing lists, and whether
  both form an equivalent xGMI hive (re-capture `ioreg` with each option
  fitted)
- Confirmed cross-card pairings so far: W6800X Duo, W6900X, Vega II
  (verify others; see next bullet for the Vega II Duo pairing)
- **Support status of 2× Vega II Duo cross-card linked (jumper or bridge):**
  this pairing may not be a configuration Apple supports (physically/technically
  achievable vs. officially supported are separate questions). Find and cite
  Apple's Mac Pro/MPX configuration matrix, and note results of an `ioreg`
  check on a real linked 2× Vega II Duo system (does the hive form with
  `XGMI_HiveSize = 4`, or does the driver refuse to link the cards?)
- Link widths per hop (intra-card vs cross-card) and whether they differ
- Bandwidth/latency of the cross-card IF hop vs intra-card hop vs PCIe
  fallback (if-bench directions 3 and 5)
- Per-slot constraints: which slot pairs the bridge supports, and per-CPU
  attachment on dual-socket parts (see [host-machines.md](host-machines.md))

## Related

- [infinity-fabric.md](infinity-fabric.md) — link architecture and bandwidth
- [host-machines.md](host-machines.md) — slots and electrical topology
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md) — how Metal sees these cards
