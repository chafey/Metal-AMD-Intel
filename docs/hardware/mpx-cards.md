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

## Related

- [infinity-fabric.md](infinity-fabric.md) — link architecture and bandwidth
- [host-machines.md](host-machines.md) — slots and electrical topology
- [../metal/gpu-exposure.md](../metal/gpu-exposure.md) — how Metal sees these cards
