# Benchmark Report: 2× W6800X Duo + RX 6900 XT — full device matrix

- **Date:** 2026-09-11
- **Author:** repo maintainer
- **Tool:** `if-bench` (per-device modes, `--device-b` optional) and
  `mtl-bench` (`--device N`), repo @ Phase 3 + all-GPU matrix update
- **Exact commands:** `./scripts/run-all-benchmarks.sh`, which runs
  `swift run --package-path tools gpu-probe --json`;
  `swift run --package-path tools if-bench -- --device-a N --mode bw,latency,host --json`
  for N = 0…4;
  `swift run --package-path tools if-bench -- --device-a A --device-b B --mode peer --json`
  for all 10 pairs A < B; and `build/tools/mtl-bench/mtl-bench --device N --json`
  for N = 0…4.
- **Build note:** `mtl-bench` is a Release build (CMake default); the
  `if-bench` runs used `swift run`'s default **debug** build. GPU-side copy
  times should be close to Release, but CPU-side encode/timing overhead in
  these numbers is inflated relative to the Release run in
  [the first report](2026-09-11-w6800x-duo-copy-paths.md).

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4, Infinity Fabric Link bridge fitted) + 1× MSI Radeon RX 6900 XT (consumer card, subsystem vendor 0x1462, plain PCIe, no xGMI properties) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

**Displays are attached to the RX 6900 XT** (maintainer setup) so the Duo
dies stay idle during measurement; the flip side is that the 6900 XT
(`dev0`) runs under continuous window-server load, which must be assumed to
affect *its* numbers (see caveats).

### Devices under test

| Metal index | Name | xGMI hive / node | Notes |
|---|---|---|---|
| dev0 | AMD Radeon RX 6900 XT | — (no xGMI keys) | display GPU |
| dev1 | W6800X Duo | hive 4 / node 2 | card A die |
| dev2 | W6800X Duo | hive 4 / node 3 | card A die |
| dev3 | W6800X Duo | hive 4 / node 1 | card B die |
| dev4 | W6800X Duo | hive 4 / node 0 | card B die |

Module membership is inferred from PCI-id adjacency established in
[first report §Methodology](2026-09-11-w6800x-duo-copy-paths.md):
{dev1, dev2} are the two dies of one Duo module (Infinity Fabric Link
jumper pair), {dev3, dev4} the other module; pairs spanning {1,2}↔{3,4}
cross cards over the Infinity Fabric Link bridge. The API exposes no
direct module-membership evidence; treat the pairing labels as inference.

## Methodology

Same measurement primitives as
[the first report](2026-09-11-w6800x-duo-copy-paths.md) (pipelined-copy
bandwidth, dependent-chain latency, IOSurface staging peer path behind a
coherence gate, `storageModeShared` host path). Differences:

- Every visible device is swept; peer mode runs **all 10 unordered pairs**.
  The coherence gate passed for all 10, including every cross-hive pair.
- `if-bench` debug build (see build note).
- No clock locking, no thermal control; single runs.
- Caveat established while interpreting the first report: single-hop rates
  measured by repeatedly copying the same working set (≤64 MiB fits the
  ~128 MB Infinity Cache) are flattered by cache residency; the dependent
  two-hop chain forces bytes end-to-end and is therefore much slower than
  the hop rates combined. Do not read hop and chain rates as additive.

## Results

### Local VRAM copy (device → own VRAM), blit, GB/s

| Size | dev0 6900XT | dev1 | dev2 | dev3 | dev4 |
|---|---|---|---|---|---|
| 1 MiB | 0.6 | 1.7 | 1.9 | 1.9 | 1.5 |
| 2 MiB | 0.8 | 5.5 | 6.8 | 7.2 | 5.1 |
| 4 MiB | 14.4 | 15.1 | 17.5 | 16.4 | 14.3 |
| 8 MiB | 37.5 | 36.9 | 37.1 | 39.1 | 41.4 |
| 16 MiB | 60.6 | 52.0 | 49.4 | 55.5 | 54.0 |
| 32 MiB | 79.9 | 66.2 | 63.8 | 66.0 | 62.5 |
| 64 MiB | **81.6** | 71.8 | **73.3** | **73.4** | 72.0 |

Kernel-path peaks: 58.8 (dev0) / 63.6–69.1 GB/s (Duo dies). The four Duo
dies are statistically identical; the 6900 XT peaks slightly higher at
32–64 MiB despite its worse small-size ramp.

Local dependent-copy latency, 4 KiB / 64 KiB / 1 MiB (µs/copy):

| | 4 KiB | 64 KiB | 1 MiB |
|---|---|---|---|
| dev0 6900XT | 33.5 | 21.1 | 30.3 |
| dev1–dev4 (Duo dies) | 3.9–10.8 | 3.9–4.0 | 5.9–6.1 |

(dev1's 4 KiB point, 10.8 µs, is the outlier of an otherwise-tight 3.9–4.0
µs cluster; dev0's latency is 3–8× the Duo dies and noisy — possibly
display-queue interference, unconfirmed.)

### Peer path within the xGMI hive (6 pairs)

Peak rates over the 4 KiB–64 MiB sweep; "2 hops" is the dependent
A→staging→B chain (GB/s at 128 MiB-total transfer, i.e. counting both
hops' bytes):

| Pair | Relation* | write hop | read hop | A→B | B→A | lat @4 KiB (µs/hop) |
|---|---|---|---|---|---|---|
| dev1↔dev2 | jumper (same module) | 24.7 / 23.8 | 98.0 / 101.1 | 8.7 | 8.6 | 150.6 |
| dev3↔dev4 | jumper (same module) | 25.8 / 24.6 | 97.4 / 93.0 | 8.9 | 8.8 | 129.6 |
| dev1↔dev3 | bridge (cross-card) | 24.9 / 25.7 | 101.2 / 105.2 | 8.8 | 8.9 | 139.9 |
| dev1↔dev4 | bridge (cross-card) | 23.7 / 24.7 | 102.9 / 96.0 | 8.9 | 8.6 | 160.8 |
| dev2↔dev3 | bridge (cross-card) | 25.0 / 25.4 | 103.4 / 104.5 | 8.9 | 8.8 | 132.6 |
| dev2↔dev4 | bridge (cross-card) | 24.9 / 24.6 | 101.9 / 98.2 | 8.9 | 8.8 | 121.4 |

\* inferred from PCI adjacency, see device table note.

All six hive pairs are indistinguishable: ~24–26 GB/s write hop,
~93–105 GB/s read hop, 8.6–8.9 GB/s end-to-end, ~120–160 µs/hop.
Jumper (same-module) and bridge (cross-card) pairs are equal within noise —
extending the first report's two-pair finding to the full 6-pair matrix.

### Peer path across the hive boundary (6900 XT ↔ Duo dies, 4 pairs)

| Pair | write hop (6900XT / Duo) | read hop (6900XT / Duo) | 6900→Duo | Duo→6900 | lat @4 KiB (µs/hop) |
|---|---|---|---|---|---|
| dev0↔dev1 | 36.2 / 23.7 | 110.2 / 100.0 | 3.4 | 1.6 | 373.8 |
| dev0↔dev2 | 35.7 / 24.8 | 104.3 / 99.0 | 3.3 | 2.9 | 5 744.3 † |
| dev0↔dev3 | 36.3 / 25.2 | 103.6 / 103.1 | 3.7 | 2.5 | 350.9 |
| dev0↔dev4 | 36.8 / 24.0 | 89.9 / 99.6 | 3.5 | 2.4 | 550.9 |

† pair dev0↔dev2's 4 KiB point is itself an outlier (5 744 µs vs 343–551 µs
on the other three pairs), and pair dev0↔dev1 hits 8 134 µs/hop at 1 MiB —
cross-hive latency numbers are wildly unstable, unlike the tight hive band.

Each isolated hop looks *normal* (the 6900 XT even writes faster than the
Duo dies), yet the dependent chain drops to 1.6–3.7 GB/s — well below the
hive band's 8.6–8.9 — and is **asymmetric**: moving data *to* the 6900 XT
is ~1.5–2× slower than moving it *from* the 6900 XT. *Inference (low
confidence):* staging pages are placed in the hive's GPU memory (first
report's finding), so every cross-hive hop adds a PCIe round-trip under
the driver's coherence handling; the exact mechanism is not observable via
the API and was not isolated.

### Host ↔ GPU (shared buffers, 64 MiB totals incl. CPU pass)

| Direction | dev0 | dev1 | dev2 | dev3 | dev4 |
|---|---|---|---|---|---|
| host→dev (total) | 1.0 | 8.1 | 5.2 | 8.3 | 5.5 |
| dev→host (total) | 0.5 | 0.7 | 0.8 | 0.7 | 0.8 |

Rough approximations (method labeled as such in tool output); these vary
substantially between runs and should not be quoted as PCIe limits.

### Metal API overhead (`mtl-bench`, ns/op)

| Benchmark | dev0 6900XT | Duo dies (range) |
|---|---|---|
| commandBuffer.alloc | 2 140 | 2 072–2 206 |
| commandBuffer.commit (empty) | 10 773 | 10 162–10 338 |
| blitEncoder create+end | 3 269 | 3 061–3 288 |
| blit.copy 64 B | 20 836 | 14 128–14 886 |
| blit.copy 1 KiB | 47 906 | 10 508–11 758 |
| blit.copy 64 KiB | 28 154 | 10 409–12 393 |
| blit.copy 1 MiB | 25 943 | 10 860–12 427 |
| renderPass setup (64×64 clear) | 14 241 | 13 795–14 087 |
| kernel dispatch (encode only) | 914 | 866–884 |
| kernel dispatch (encode+commit) | **141 146** | 23 382–25 682 |

Command-buffer/encoder primitives are identical across devices, but the
6900 XT pays 2–5× on small blit copies and ~6× on committed dispatches.
Because this device also serves the window server, contention is a likely
contributor (inference); a run with displays on the Duo side would
disentangle silicon vs. contention.

## Raw data

23 JSON captures under [`raw/`](raw/), prefix `2026-09-11-matrix-`:
`gpu-probe`, `devices`, `if-bench-dev{0..4}`,
`if-bench-peer{A}-{B}` (all 10 pairs), `mtl-bench-dev{0..4}`.
Progress log: `build/results/run.progress.log` (not archived).

## Conclusions

- **Within the xGMI hive, the staging route is uniform regardless of
  topology**: jumper and bridge pairs all measure 8.6–8.9 GB/s and
  ~120–160 µs/hop. With 6/6 pairs agreeing, the first report's "no
  measurable Infinity Fabric Link bridge benefit via this route" now has
  full-matrix support.
- **Cross-hive (xGMI hive ↔ plain-PCIe card) peer transfers are the weak
  path**: 2-hop chains collapse to 1.6–3.7 GB/s with direction asymmetry
  and unstable latency (343–5 744 µs/hop) even though each hop measured in
  isolation looks healthy. Designs that share buffers between an MPX hive
  and a non-hive GPU on this OS should expect this route to be unusable
  for bulk or latency-sensitive work (see `docs/metal/gotchas.md`).
- **Local copy ceilings cluster at 62–82 GB/s across three different
  RDNA2 parts**, reinforcing that the local-copy ceiling is a macOS
  driver/GPU-path property, not Duo-specific. The 6900 XT's advantage at
  32–64 MiB is unexplained; display load makes its small-size and latency
  numbers suspect.
- **API overhead is device-dependent on small submissions** (dispatch
  commit 141 µs vs ~24 µs) — measure per-device, don't assume the
  system-default device is representative.
- Single debug-build runs; before quoting marginal differences, re-run in
  Release with clocks steady and displays disconnected from the measured
  GPU.
