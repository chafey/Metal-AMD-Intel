# Benchmark Report: 2× W6800X Duo — peer-group P2P pull matrix (all 6 die pairs)

- **Date:** 2026-09-11 (p2p pass includes latency rows; supersedes an
  earlier same-day p2p capture without them)
- **Author:** repo maintainer
- **Tool:** `if-bench` (repo @ Phase 3 + peer-group P2P path), Release build
  (`tools/.build/release/if-bench`)
- **Exact command (per pair):**
  `tools/.build/release/if-bench --device-a A --device-b B --mode peer --json`
  (p2p is the default `--peer-path`), with (A,B) ∈ {(1,2), (3,4), (1,3),
  (1,4), (2,3), (2,4)} — size range 4 KiB → 64 MiB, powers of two

Companion to [the Duo copy-paths report](2026-09-11-w6800x-duo-copy-paths.md),
which adds the staging fallback, local/host routes, and full machine
details. Scope is the two Duo modules only; the machine's third GPU
(RX 6900 XT, display) is deliberately not measured here.

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
- **Bandwidth timing:** `n` pulls pipelined in one command buffer after
  one warm batch; reported seconds are per single pull. Blit
  (`copyFromBuffer`) and compute-kernel reads of the same remote view are
  both swept, both directions per pair. Release build throughout.
- **Latency timing (`p2pLatency`):** alternating single pulls (B reads
  A's view, then A reads B's view), **each in its own command buffer with
  commit+wait** — every pull is a fully serialized transaction. Reported
  as µs per one-way pull (total ÷ 2·roundTrips, 200 round trips), sizes
  4 KiB → 4 MiB. Not data-dependent (views are read-only, so a dependent
  chain would need two hops); includes command-submission cost.
- **Caveats:** `n` pulls of one buffer can be Infinity-Cache-assisted
  (128 MB per die): plateau numbers are same-buffer upper bounds. Bandwidth
  moves ±1–1.5 GB/s between sessions (see conclusions); quote ranges, not
  points.

## Results

Blit pulls, GB/s (range = the pair's two directions):

| Pair | Link | 1 MiB | 8 MiB | 32 MiB | 64 MiB |
|---|---|---|---|---|---|
| dev1↔2 | jumper | 30.1–32.8 | 35.2–35.7 | 36.8–37.0 | 37.0 |
| dev3↔4 | jumper | 31.9–32.7 | 34.9–35.5 | 36.2 | 36.9–37.0 |
| dev1↔3 | bridge | 31.8–33.8 | 35.8–36.0 | 37.3–37.5 | 37.6–37.7 |
| dev1↔4 | bridge | 33.1–33.6 | 34.0–34.5 | 37.4–38.0 | **38.3–38.4** |
| dev2↔3 | bridge | 34.7–34.9 | 34.8–36.8 | 37.6–37.9 | **38.3–38.5** |
| dev2↔4 | bridge | 32.9–34.2 | 35.5–36.3 | 37.0–37.1 | 37.8–37.9 |

Full-size curve (min–max GB/s across all six pairs, both directions):

| Size | blit pull | kernel pull |
|---|---|---|
| 4 KiB | 1.9–2.4 | 0.3–0.4 |
| 16 KiB | 7.1–8.0 | 1.4–1.6 |
| 64 KiB | 14.8–19.7 | 3.7–5.8 |
| 256 KiB | 25.7–29.8 | 14.3–15.2 |
| 1 MiB | 30.1–34.9 | 20.4–25.7 |
| 4 MiB | 32.4–36.6 | 22.1–32.3 |
| 16 MiB | 35.1–37.5 | 28.3–36.1 |
| 64 MiB | 36.9–38.5 | 35.8–37.5 |

Compute-kernel pulls read the same remote views without the blitter; they
run 1–3 GB/s below blit at ≥32 MiB and fall away sharply at small sizes.

**Pull latency** (µs per one-way serialized pull, commit+wait each;
median-of-sizes view of the sweep):

| Pair | Link | 4 KiB | 64 KiB | 1 MiB | 4 MiB |
|---|---|---|---|---|---|
| dev1↔2 | jumper | 61.3 | 58.8 | 97.6 | 227.2 |
| dev3↔4 | jumper | 54.3 | 73.6 | 84.3 | 228.8 |
| dev1↔3 | bridge | 58.1 | 67.2 | 86.4 | 224.4 |
| dev1↔4 | bridge | 58.8 | 59.1 | 82.1 | 219.4 |
| dev2↔3 | bridge | 56.3 | 98.0 | 99.6 | 223.9 |
| dev2↔4 | bridge | 60.7 | 54.2 | 84.9 | 224.7 |

Small pulls floor at **54–61 µs** regardless of pair or link (the
1 MiB/4 MiB rows grow with transfer time because, unlike the bandwidth
sweep, serialized pulls do not pipeline). For comparison, the IOSurface
staging route measures 121–148 µs per hop in a *dependent two-hop chain*
(different protocol; see the matrix report).

## Raw data

6 JSON captures in [`raw/`](raw/) shared with the matrix report:
`2026-09-11-matrix-if-bench-peer-p2p-dev{1-2,3-4,1-3,1-4,2-3,2-4}.json`.
Each contains the device table (with `peerGroupIDHex`), machine block,
coherence notes, per-size bandwidth rows for both paths and directions,
and latency rows (4 KiB → 4 MiB). Cross-hive pairs (hive die ↔ the
unmeasured dev0) skip with a `devices not in a common Metal peer group`
note; the tool was verified to emit that note-and-skip, and the
supporting captures live in git history.

## Conclusions

- **The xGMI hive behaves as six equivalent fast P2P paths:** every pair
  plateaus at 36.9–38.5 GB/s (peak 38.5 GB/s) at one hop, ~4× the best
  two-hop IOSurface staging chain (~10 GB/s).
- **Jumper vs bridge is indistinguishable session-to-session:** an
  earlier capture showed jumper ~1–1.5 GB/s ahead; this capture shows the
  top pair on the *bridge*. Treat jumper and bridge as equivalent for
  capacity planning (both ≥36.9 GB/s plateau), and quote bandwidth as
  ranges with ±1.5 GB/s session variance.
- **Latency floor ≈ 55–60 µs per one-way pull** (serialized, submission +
  link), half the per-hop cost of the staging dependent chain — and a
  remote-view protocol needs one pull per transfer where staging needs
  two hops.
- **Bandwidth knee is early:** ≥30 GB/s from 1 MiB, within ~3% of plateau
  by 16 MiB. Kernel reads of remote views are viable but strictly worse
  than blit at every size here.
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
