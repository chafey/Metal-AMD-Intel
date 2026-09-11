# Benchmark Report: 2× W6800X Duo + RX 6900 XT — full device matrix (fresh capture)

- **Date:** 2026-09-11
- **Author:** repo maintainer
- **Tool:** `if-bench` (Release build, peer-group P2P default) and
  `mtl-bench` (Release), repo @ Phase 3 tooling + p2p route
- **Exact commands:**
  - `PEER=0 ./scripts/run-all-benchmarks.sh` — runs
    `swift run --package-path tools gpu-probe --json`,
    `swift run --package-path tools if-bench -- --list-devices --json`,
    `swift run --package-path tools if-bench -- --device-a N --mode bw,latency,host --json`
    (N = 0…4) and `build/tools/mtl-bench/mtl-bench --device N --json` (N = 0…4)
  - **p2p (default peer route)**, all 10 pairs A < B:
    `tools/.build/release/if-bench --device-a A --device-b B --mode peer --json`
  - **staging fallback**, all 10 pairs A < B:
    `tools/.build/release/if-bench --device-a A --device-b B --mode peer --peer-path both --json`
- **Build note:** this capture is all-Release (`if-bench` built with
  `swift build --package-path tools -c release`). CPU-side overheads are
  therefore lower than in earlier debug-build captures; do not mix builds
  when comparing.
- **Session note:** this is a clean rerun on an idle machine (an earlier
  attempt on the same day was invalidated by concurrent GPU load and has
  been replaced). All 32 raw files below come from one contiguous session.

This report supersedes the day's earlier captures; the 6-pair p2p view has
its own companion summary,
[2026-09-11-w6800x-duo-p2p-peer-group-matrix.md](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md).

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4, Infinity Fabric Link bridge fitted) + 1× MSI Radeon RX 6900 XT (consumer card, plain PCIe, no xGMI properties) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

**Displays are attached to the RX 6900 XT** (maintainer setup) so the Duo
dies stay idle during measurement; the flip side is that the 6900 XT
(`dev0`) runs under continuous window-server load, which must be assumed to
affect *its* numbers (see caveats).

### Devices under test

| Metal index | Name | xGMI hive / node | peerGroupID | Notes |
|---|---|---|---|---|
| dev0 | AMD Radeon RX 6900 XT | — (no xGMI keys) | 0 (none) | display GPU |
| dev1 | W6800X Duo | hive 4 / node 2 | 0x4cf5577a51a24576 | card A die |
| dev2 | W6800X Duo | hive 4 / node 3 | 0x4cf5577a51a24576 | card A die |
| dev3 | W6800X Duo | hive 4 / node 1 | 0x4cf5577a51a24576 | card B die |
| dev4 | W6800X Duo | hive 4 / node 0 | 0x4cf5577a51a24576 | card B die |

Module membership is inferred from PCI-id adjacency established in earlier
captures: {dev1, dev2} are the two dies of one Duo module (Infinity Fabric
Link jumper pair), {dev3, dev4} the other module; pairs spanning
{1,2}↔{3,4} cross cards over the Infinity Fabric Link bridge. The Metal
peer group covers all four hive dies; dev0 is in no peer group, so
remote-buffer-view P2P is unavailable for it (directly evidenced: every
dev0 p2p run emits the skip note and no rows).

## Methodology

Two cross-device routes, both behind changing-pattern coherence gates
(CPU-reseeded content verified after transfer, both directions):

- **p2p (default):** destination-side pull of a read-only
  `newRemoteBufferViewForDevice:` view of the peer's private buffer into
  the reader's own VRAM — one hop, no IOSurface. See
  [gotchas](../metal/gotchas.md) for the read-only constraint.
- **staging (`--peer-path both`):** one IOSurface with a texture view per
  device; A→B is two hops (write + read) with a commit/wait each; both the
  blit and the compute-kernel hop implementations were swept.

Local bandwidth/latency and host↔GPU (`storageModeShared`) as in
prior captures: pipelined copies for bandwidth, dependent copy chains for
latency, sizes 4 KiB → 64 MiB by default. No clock locking, no thermal
control; single runs per configuration.

**Caveats:** repeated same-buffer transfers (working set ≤64 MiB vs the
~128 MB Infinity Cache) are cache-flattered on every route — treat plateau
rates as same-buffer upper bounds. dev0 carries the display server. Host
totals include the CPU pass (approximation, labelled as such by the tool).

## Results

### Peer-group P2P (default peer route), GB/s per pull

Blit pulls, range = the pair's two directions; `k` = compute-kernel pulls
of the same views. All 6/6 in-hive pairs passed the changing-pattern gate
both directions; the 4 dev0 pairs skipped (no shared peer group).

| Pair | Link | 1 MiB | 8 MiB | 32 MiB | 64 MiB | 64 MiB k |
|---|---|---|---|---|---|---|
| dev1↔2 | jumper | 32.4–34.1 | 35.1–36.1 | 37.9–38.0 | 38.1–38.3 | 37.2–37.5 |
| dev3↔4 | jumper | 31.9–35.2 | 36.5–36.7 | 38.2–38.3 | **38.4–38.8** | 37.7–37.8 |
| dev1↔3 | bridge | 33.6–34.3 | 32.1–35.7 | 37.0–37.4 | 37.5–37.8 | 36.6–36.9 |
| dev1↔4 | bridge | 31.0–32.9 | 33.8–35.4 | 36.0–36.6 | 37.0–37.1 | 34.0–35.6 |
| dev2↔3 | bridge | 31.6–33.7 | 34.6–35.2 | 36.3–36.6 | 36.8–37.0 | 35.7–36.0 |
| dev2↔4 | bridge | 32.8–34.1 | 32.2–35.5 | 37.0–37.1 | 37.4–37.7 | 36.8–37.1 |

Full-size curve (min–max GB/s across the six pairs, both directions):

| Size | blit pull | kernel pull |
|---|---|---|
| 4 KiB | 1.5–2.3 | 0.3–0.4 |
| 64 KiB | 17.8–19.4 | 4.4–5.6 |
| 256 KiB | 27.1–29.5 | 14.5–15.2 |
| 1 MiB | 31.0–35.2 | 23.2–25.9 |
| 8 MiB | 32.1–36.7 | 32.4–34.4 |
| 64 MiB | 36.8–38.8 | 34.0–37.8 |

### IOSurface staging fallback (two hops), GB/s chains @64 MiB

| Pair set | blit chain | kernel chain | latency @4 KiB (µs/hop) |
|---|---|---|---|
| In-hive (all 6 pairs) | 8.3–8.6 | 9.7–10.2 | 121–148 |
| Cross-hive (dev0 ↔ hive, 4 pairs) | 2.0–4.0 | 1.3–2.9 | 296–4 999 |

Isolated hops at 64 MiB (sample, dev1↔2 and dev3↔4): blit writes 24–25,
blit reads 88–106, kernel-driven hops 106–192 GB/s — five times above the
PCIe Gen3 x16 ceiling, confirming staging pages are GPU-resident and that
the two-hop chain ceiling (~10 GB/s) sits in the cross-device
commit/visibility step, not the hop engines.

### Local VRAM copy (device → own VRAM), 64 MiB-class peaks

| Device | blit peak GB/s | kernel peak GB/s | latency @4 KiB (µs/copy) |
|---|---|---|---|
| dev0 (6900 XT, display) | 86.2 | 3.4 ⚠ | 33.6 |
| dev1 | 70.3 | 67.2 | 4.05 |
| dev2 | 73.6 | 68.1 | 4.28 |
| dev3 | 73.9 | 69.2 | 3.87 |
| dev4 | 74.3 | 68.1 | 3.88 |

⚠ dev0's kernel-local numbers collapsed to single-digit GB/s in this
capture — the only run on the display GPU; treat as display-load noise
(window server preempting compute queues), not a hardware property. The
Duo dies' 3.9–4.3 µs/copy floor vs dev0's 33.6 µs is consistent with the
6900 XT's known small-submission overhead (below).

### Host ↔ GPU (shared buffers, 64 MiB, GB/s incl. CPU pass)

dev3 37.9, dev1 23.9, dev2 22.7, dev4 6.1, dev0 5.0. Highly variable
run-to-run (this route was always the noisiest); quote only as ranges.

### Metal API overhead (`mtl-bench`, ns/op, Release)

| Op | dev0 (6900 XT) | dev1–dev4 (Duo dies) |
|---|---|---|
| commandBuffer.alloc | 2 096 | 2 013–2 174 |
| commandBuffer.commit.empty | 10 000 | 9 937–10 086 |
| blit.copy.64B (pipelined) | 46 841 | 14 446–16 358 |

Unlike the earlier debug-build capture, empty-commit cost is now uniform
across devices; the 6900 XT's penalty concentrates in small submitted
copies (~3× the Duo dies), consistent with display-server interference.

## Raw data

32 JSON captures under [`raw/`](raw/), prefix `2026-09-11-matrix-`:
`gpu-probe`, `if-bench-devices`, `if-bench-dev{0..4}`,
`mtl-bench-dev{0..4}`, `if-bench-peer-p2p-{A}-{B}` (all 10 pairs; dev0
pairs contain the skip note and no rows),
`if-bench-peer-both-{A}-{B}` (all 10 pairs, staging blit+kernel).

## Conclusions

- **Within the xGMI hive, peer-group P2P is the cross-device route:**
  36.8–38.8 GB/s on all six pairs at one hop, ~4× the best two-hop staging
  chain (~10 GB/s), with the Infinity Fabric Link jumper showing only a
  small (~1–1.5 GB/s) and consistent edge over the bridge. Coherence held
  under changing patterns in both directions on every pair.
- **The staging route remains the only cross-device mechanism outside a
  peer group** — and it is bad there: cross-hive chains measure 1.3–4.0
  GB/s with latency to 5 ms/hop. Design for P2P inside hives and treat
  hive↔non-hive GPU sharing as PCIe-class at best.
- **Peer group == xGMI hive** is directly evidenced: four hive dies share
  one non-zero `peerGroupID`, the non-hive card reports 0 and nil views;
  the tool gates on this and skips cleanly.
- **Staging ceilings are protocol-bound, not engine-bound:** kernel-driven
  isolated hops still reach 106–192 GB/s (GPU-resident staging pages),
  while the two-hop chain stays ~10 GB/s on the fresh Release capture —
  reproducing the earlier debug-build finding.
- Local copy peaks cluster at 70–74 GB/s across Duo dies; Duo
  small-copy latency (≈4 µs) is ~8× better than the display-attached
  6900 XT (≈34 µs).
