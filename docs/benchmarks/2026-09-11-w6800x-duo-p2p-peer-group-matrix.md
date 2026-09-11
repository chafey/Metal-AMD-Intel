# Benchmark Report: 2× W6800X Duo — peer-group P2P pull matrix (all 6 die pairs)

- **Date:** 2026-09-11
- **Author:** repo maintainer
- **Tool:** `if-bench` (repo @ Phase 3 + peer-group P2P path), Release build
  (`tools/.build/release/if-bench`)
- **Exact command (per pair):**
  `tools/.build/release/if-bench --device-a A --device-b B --mode peer --json`
  (p2p is the default `--peer-path`), with (A,B) ∈ {(1,2), (3,4), (1,3),
  (1,4), (2,3), (2,4)} — size range 4 KiB → 64 MiB, powers of two

Companion to [the full-device-matrix report](2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md),
which adds the staging fallback, local/host routes, the RX 6900 XT, and
full machine details. Both come from one clean idle-machine session.

## Machine

Mac Pro (2019) (MacPro7,1), Intel Xeon W-3245 @ 3.20 GHz (16c/32t), 192 GB
RAM, macOS 26.6.2 (25G83), AMDRadeonX6000* 7.0.1 / IOAcceleratorFamily2
487.4.3. 2× Radeon Pro W6800X Duo: four dies, one xGMI hive of 4, Infinity
Fabric Link bridge fitted. All four dies share
`peerGroupID 0x4cf5577a51a24576` (printed per device by `if-bench`).

dev1/dev2 = the two dies of module A, dev3/dev4 = module B. Pairs dev1↔2
and dev3↔4 communicate over the on-module **Infinity Fabric Link jumper**;
the other four pairs cross cards over the **Infinity Fabric Link bridge**.

## Methodology

- **Route:** Metal peer-group P2P. The *destination* device's own queue
  pulls a read-only `newRemoteBufferViewForDevice:` view of a
  `storageModePrivate` buffer in the source GPU's VRAM into the
  destination's own VRAM. One hop per transfer; `bytes = buffer size`.
  Remote views are read-only on this driver, so pull is the only legal
  direction (see [gotchas](../metal/gotchas.md)).
- **Coherence gate first:** before each pair's sweep, 4 rounds of
  CPU-reseeded *changing* patterns are pulled and verified in both
  directions. **All 6/6 pairs passed.** A failed gate drops p2p rows; none
  did here.
- **Timing:** `n` pulls pipelined in one command buffer after one warm
  batch; reported seconds are per single pull. Blit (`copyFromBuffer`) and
  compute-kernel reads of the same remote view are both swept, both
  directions per pair. Release build throughout.
- **Caveat:** `n` pulls of one buffer can be Infinity-Cache-assisted
  (128 MB per die): plateau numbers are same-buffer upper bounds, not
  cold-data numbers.

## Results

Blit pulls, GB/s (range = the pair's two directions):

| Pair | Link | 1 MiB | 8 MiB | 32 MiB | 64 MiB |
|---|---|---|---|---|---|
| dev1↔2 | jumper | 32.4–34.1 | 35.1–36.1 | 37.9–38.0 | 38.1–38.3 |
| dev3↔4 | jumper | 31.9–35.2 | 36.5–36.7 | 38.2–38.3 | **38.4–38.8** |
| dev1↔3 | bridge | 33.6–34.3 | 32.1–35.7 | 37.0–37.4 | 37.5–37.8 |
| dev1↔4 | bridge | 31.0–32.9 | 33.8–35.4 | 36.0–36.6 | 37.0–37.1 |
| dev2↔3 | bridge | 31.6–33.7 | 34.6–35.2 | 36.3–36.6 | 36.8–37.0 |
| dev2↔4 | bridge | 32.8–34.1 | 32.2–35.5 | 37.0–37.1 | 37.4–37.7 |

Full-size curve (min–max GB/s across all six pairs, both directions):

| Size | blit pull | kernel pull |
|---|---|---|
| 4 KiB | 1.5–2.3 | 0.3–0.4 |
| 16 KiB | 6.2–7.9 | 1.4–1.7 |
| 64 KiB | 17.8–19.4 | 4.4–5.6 |
| 256 KiB | 27.1–29.5 | 14.5–15.2 |
| 1 MiB | 31.0–35.2 | 23.2–25.9 |
| 4 MiB | 32.0–36.8 | 27.9–32.8 |
| 16 MiB | 35.5–38.0 | 32.8–36.4 |
| 64 MiB | 36.8–38.8 | 34.0–37.8 |

Compute-kernel pulls read the same remote views without the blitter; they
run 1–3 GB/s below blit at ≥32 MiB and fall away sharply at small sizes.

## Raw data

6 JSON captures in [`raw/`](raw/) shared with the matrix report:
`2026-09-11-matrix-if-bench-peer-p2p-dev{1-2,3-4,1-3,1-4,2-3,2-4}.json`.
Each contains the device table (with `peerGroupIDHex`), machine block,
coherence notes, and per-size rows for both paths and directions. The four
dev0 pair files (`…-p2p-0-{1..4}.json`) hold the cross-hive skip note.

## Conclusions

- **The xGMI hive behaves as six equivalent fast P2P paths:** every pair
  plateaus at 36.8–38.8 GB/s (peak 38.8 GB/s, dev3↔4 jumper).
  This is ~4× the best IOSurface staging chain (~10 GB/s) measured on the
  same session, at one hop instead of two.
- **Jumper vs bridge barely matters above ~32 MiB:** the jumper edge is a
  consistent ~1–1.5 GB/s across pairs and directions, but under the
  repeated-buffer cache caveat it should be quoted as small-but-real, not
  as a link-width measurement.
- **Bandwidth knee is early:** 31–35 GB/s already at 1 MiB and within
  ~3% of plateau by 16 MiB; below ~256 KiB per-pull overhead dominates
  (~3/4 of plateau by 256 KiB). Kernel reads of remote views are viable
  but strictly worse than blit at every size here.
- **Coherence held:** destination-side pulls observed CPU-reseeded,
  changing source content on every round in both directions — the
  visibility property a llama.cpp/toshllm-style remote-view protocol
  depends on, which those implementations do not themselves test.
- Docs updated as a result:
  [infinity-fabric.md](../hardware/infinity-fabric.md) (bandwidth table +
  findings), [gotchas.md](../metal/gotchas.md) (remote-view read-only
  abort; peer-group ↔ hive mapping),
  [gpu-exposure.md](../metal/gpu-exposure.md) (cross-device sharing
  mechanisms), [if-bench README](../../tools/if-bench/README.md)
  (`--peer-path`, p2p default).
