# Benchmark Report: 2× W6800X Duo — copy paths (p2p, staging, local, host) and API overhead

- **Date:** 2026-09-11
- **Author:** repo maintainer
- **Tool:** `if-bench` (peer-group P2P default route) and `mtl-bench`,
  Release pair builds
- **Exact commands:**
  - per-device (local bw/latency + host):
    `swift run --package-path tools if-bench -- --device-a N --mode bw,latency,host --json`
    (N = 1…4), plus `gpu-probe --json` and `if-bench -- --list-devices --json`
  - mtl-bench: `build/tools/mtl-bench/mtl-bench --device N --json` (N = 1…4)
  - p2p (default route), all 6 Duo die pairs:
    `tools/.build/release/if-bench --device-a A --device-b B --mode peer --json`
  - staging fallback, same 6 pairs:
    `tools/.build/release/if-bench --device-a A --device-b B --mode peer --peer-path both --json`
- **Build note:** pair sweeps used the Release binary directly. The
  per-device files ran through `swift run` (debug build): GPU-side copy
  times are largely unaffected, CPU-side encode/timing in those files is
  inflated relative to Release.
- **Scope note:** this report covers the two W6800X Duo modules only. An
  RX 6900 XT is present in the machine as dev0 (display GPU) and appears
  in the environment listings (`raw/…gpu-probe.json`,
  `raw/…if-bench-devices.json`), but no 6900 XT measurements are included
  in this report set; measurements that included it (2026-09-11 cross-hive
  captures) were removed from `raw/` and are recoverable from git history.

The p2p route has its own detailed view:
[2026-09-11-w6800x-duo-p2p-peer-group-matrix.md](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md).

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) measured | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4, Infinity Fabric Link bridge fitted) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

### Devices under test

| Metal index | Name | xGMI hive / node | peerGroupID |
|---|---|---|---|
| dev1 | W6800X Duo | hive 4 / node 2 | 0x4cf5577a51a24576 |
| dev2 | W6800X Duo | hive 4 / node 3 | 0x4cf5577a51a24576 |
| dev3 | W6800X Duo | hive 4 / node 1 | 0x4cf5577a51a24576 |
| dev4 | W6800X Duo | hive 4 / node 0 | 0x4cf5577a51a24576 |

{dev1, dev2} are the two dies of one Duo module (Infinity Fabric Link
jumper pair), {dev3, dev4} the other; pairs spanning {1,2}↔{3,4} cross
cards over the Infinity Fabric Link bridge. All four share one Metal peer
group (= the xGMI hive).

## Methodology

Two cross-device routes, both behind changing-pattern coherence gates
(CPU-reseeded content verified after transfer, both directions):

- **p2p (default):** destination-side pull of a read-only
  `newRemoteBufferViewForDevice:` view of the peer's private buffer into
  the reader's own VRAM — one hop, no IOSurface; serialized-pull latency
  rows (µs per one-way pull, commit+wait each). Details and full tables in
  the companion p2p report. See [gotchas](../metal/gotchas.md) for the
  read-only constraint.
- **staging (`--peer-path both`):** one IOSurface with a texture view per
  device; A→B is two hops (write + read) with a commit/wait each; blit and
  compute-kernel hop implementations both swept; latency = dependent
  two-hop chain.

Local bandwidth/latency and host↔GPU (`storageModeShared`) as before:
pipelined copies for bandwidth, dependent copy chains for latency, 4 KiB →
64 MiB. No clock locking, no thermal control; single runs.

**Caveats:** repeated same-buffer transfers (≤64 MiB working set vs the
~128 MB Infinity Cache) are cache-flattered on every route — plateau rates
are same-buffer upper bounds. Cross-run p2p bandwidth variance is ±1–1.5
GB/s (see companion report).

## Results

### Peer-group P2P (default peer route), summary

All 6 pairs (2 jumper, 4 bridge) plateau **36.9–38.5 GB/s** blit at 64 MiB
(kernel reads 35.8–37.5), with a **54–61 µs** serialized one-way pull
latency floor; 6/6 coherence gates passed. Jumper vs bridge is
indistinguishable within session variance. Full tables, curves and
latency: [companion p2p report](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md).

### IOSurface staging fallback (two hops), GB/s chains @64 MiB

| Pairs | blit chain | kernel chain | latency @4 KiB (µs/hop) |
|---|---|---|---|
| dev1↔2 (jumper) | 8.4–8.6 | 9.7–10.1 | 139.7 |
| dev3↔4 (jumper) | 8.5–8.6 | 10.2 | 122.0 |
| dev1↔3 (bridge) | 8.3–8.4 | 9.7–10.2 | 138.3 |
| dev1↔4 (bridge) | 8.5–8.6 | 10.2 | 147.8 |
| dev2↔3 (bridge) | 8.5–8.6 | 9.9–10.1 | 120.7 |
| dev2↔4 (bridge) | 8.4–8.6 | 9.8–10.1 | 121.1 |

Isolated hops at 64 MiB (dev1↔2 and dev3↔4): blit writes 24–25, blit reads
88–106, kernel-driven hops 106–192 GB/s — far above the PCIe Gen3 x16
ceiling, confirming staging pages are GPU-resident and that the two-hop
chain ceiling (~10 GB/s) sits in the cross-device commit/visibility step,
not the hop engines. Staging is **topology-blind** (all six pairs within
0.3 GB/s of each other), unlike p2p's raw link speed.

### Local VRAM copy (device → own VRAM), 64 MiB-class peaks

| Device | blit peak GB/s | kernel peak GB/s | latency @4 KiB (µs/copy) |
|---|---|---|---|
| dev1 | 70.3 | 67.2 | 4.05 |
| dev2 | 73.6 | 68.1 | 4.28 |
| dev3 | 73.9 | 69.2 | 3.87 |
| dev4 | 74.3 | 68.1 | 3.88 |

### Host ↔ GPU (shared buffers, 64 MiB, GB/s incl. CPU pass)

dev3 37.9, dev1 23.9, dev2 22.7, dev4 6.1. Highly variable run-to-run
(the noisiest route); quote only as ranges.

### Metal API overhead (`mtl-bench`, ns/op, Release)

| Op | dev1 | dev2 | dev3 | dev4 |
|---|---|---|---|---|
| commandBuffer.alloc | 2 174 | 2 021 | 2 075 | 2 013 |
| commandBuffer.commit.empty | 10 086 | 10 051 | 9 937 | 10 057 |
| blit.copy.64B (pipelined) | 14 446 | 14 879 | 16 358 | 15 469 |

Uniform across the four Duo dies.

## Raw data

22 JSON captures under [`raw/`](raw/), prefix `2026-09-11-matrix-`:
`gpu-probe`, `if-bench-devices` (environment listings; they include the
unmeasured dev0), `if-bench-dev{1..4}`, `mtl-bench-dev{1..4}`,
`if-bench-peer-p2p-{A}-{B}` and `if-bench-peer-both-{A}-{B}` (all six Duo
die pairs). No 6900 XT measurement files are included; earlier same-day
captures that measured it are recoverable from git history.

## Conclusions

- **Within the xGMI hive, peer-group P2P is the cross-device route:**
  36.9–38.5 GB/s at one hop and a 54–61 µs serialized-pull latency floor,
  ~4× the best two-hop staging chain (~10 GB/s, 121–148 µs/hop). Coherence
  held on every pair under changing patterns in both directions.
- **The staging route is topology-blind** (8.3–8.6 GB/s blit chains on all
  six pairs, jumper and bridge identical) while p2p sees the fabric
  directly — staging's ceiling is the commit/visibility protocol, not the
  link. Staging remains relevant only where pull is impossible
  (push-style sharing) or across peer groups.
- **Peer group == xGMI hive** on this driver: all four hive dies share one
  non-zero `peerGroupID` (device table, every raw file).
- Local copy peaks cluster at 70–74 GB/s with ~4 µs small-copy latency on
  all four dies; API overhead is uniform across them (~2 µs alloc,
  ~10 µs empty commit, 14.4–16.4 µs pipelined 64 B copy).
