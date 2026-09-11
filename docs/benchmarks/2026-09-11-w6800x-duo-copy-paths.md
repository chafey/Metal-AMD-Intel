# Benchmark Report: 2× W6800X Duo — copy paths and API overhead

- **Date:** 2026-09-11
- **Author:** repo maintainer
- **Tool:** `if-bench` v1 and `mtl-bench` (repo @ Phase 3)
- **Exact command:** `swift run --package-path tools if-bench -- --json`,
  `swift run --package-path tools if-bench -- --device-a 0 --device-b 2
  --mode peer --json` and `build/tools/mtl-bench/mtl-bench --json`
  (release builds)

## Machine

| Field | Value |
|---|---|
| Model | Mac Pro (2019) (MacPro7,1) |
| CPU | Intel Xeon W-3245 @ 3.20 GHz (16c/32t) |
| RAM | 192 GB |
| macOS | 26.6.2 (25G83) |
| GPU(s) & slots | 2× Radeon Pro W6800X Duo (4 dies, xGMI hive of 4) |
| IOAccelerator version | IOAcceleratorFamily2 487.4.3, AMDRadeonX6000* 7.0.1 |

Device pairing under test: Metal devices 0 and 1 (`registryID`
`0x1_0000_0DA6` / `0x1_0000_0D82`, each its own `GFX0` PCI function,
`XGMI_NodeIndex` 3 and 2 of `XGMI_HiveSize` 4). This machine has an Infinity
Fabric Link bridge fitted (maintainer-confirmed 2026-09-11): each Duo's
on-module Infinity Fabric Link jumper forms a 2-GPU domain, and the bridge
joins the two domains into the observed single 4-node hive.

## Methodology

- **Bandwidth:** pipelined copies committed as one command buffer; warmup
  pass first; iterations sized for ~64 MiB per timed batch; alternating copy
  direction (bounded working set). Sizes 4 KiB → 64 MiB, powers of two.
- **Latency:** dependent copy chains (each copy reads the previous copy's
  output); local ping-pong 200 round trips; peer round trip 100 repetitions
  of four dependent hops (A→staging, staging→B, B→staging, staging→A), each
  hop a commit + `waitUntilCompleted` (so per-hop time includes
  submit/retire overhead).
- **Peer path:** Metal exposes no direct device-to-device buffer copy; the
  supported route is one IOSurface with an `MTLTexture` view on each device
  ("staging"). A→B is two hops (write + read). A coherence gate (pattern
  write on A, read-back on B) runs before the sweep; it passed on both
  device pairs. Two pairs were swept: devices 0↔1 and 0↔2. PCI functions
  0x…0656/0x…065a (devices 0/1) are adjacent ids and 0x…06d7 (device 2) is
  not, so 0↔1 is inferred to be the two dies of one module and 0↔2
  cross-card over the bridge; the API offers no direct module-membership
  evidence.
- **Host path:** `storageModeShared` (host-RAM-backed on Intel) buffers;
  totals include the CPU memset/read pass (approximation, see caveats).
- **mtl-bench:** Objective-C++ against the system Metal headers; loop
  counts 2 k–100 k; pipelined where noted.
- No clock locking or thermal control; numbers are single runs.

## Results

### Local VRAM copy (device → own VRAM), blit encoder

| Size | Bandwidth (GB/s) |
|---|---|
| 64 KiB | 0.01 |
| 1 MiB | 1.72 |
| 4 MiB | 16.96 |
| 8 MiB | 33.14 |
| 16 MiB | 52.66 |
| 32 MiB | 44.02 |
| 64 MiB | 67.03 |

Local dependent-copy latency: **3.96–5.99 µs/copy** for 64 KiB–1 MiB
(14.87 µs at 4 MiB). The kernel-driven copy path matched blit within ~10 %
except two high-variance points (13–14 GB/s at 16–32 MiB vs 33–63 GB/s at
neighbouring sizes) — clock/DVFS noise, not re-investigated.

### Cross-device (IOSurface staging), device 0 ↔ device 1

| Direction | Bandwidth (GB/s, peak) | At size |
|---|---|---|
| dev0 → staging (write) | 22.6 | 16 MiB |
| staging → dev0 (read) | 88.1 | 32 MiB |
| dev1 → staging (write) | 24.4 | 64 MiB |
| staging → dev1 (read) | 97.5 | 64 MiB |
| dev0 → dev1 (2 hops) | 8.5 | 128 MiB-total |
| dev1 → dev0 (2 hops) | 7.3 | 128 MiB-total |

Dependent peer round-trip latency: **170 µs/hop** at 4 KiB, 407 µs/hop at
1 MiB (dominated by the commit + wait per hop).

### Cross-device peer path, same-module vs cross-card (dev0↔1 vs dev0↔2)

| Metric | dev0↔dev1 (same module?) | dev0↔dev2 (cross-card, bridged) |
|---|---|---|
| dev→staging write (peak) | 22.6–24.4 GB/s | 25.0–25.7 GB/s |
| staging→dev read (peak) | 88.1–97.5 GB/s | 78.9–101.3 GB/s |
| 2-hop A→B (peak) | 7.3–8.5 GB/s | 8.0–8.8 GB/s |
| latency @4 KiB | 170 µs/hop | 223 µs/hop |

The two pairs are statistically indistinguishable on bandwidth: the
staging route's cost is dominated by per-hop commit/wait, not by which
physical path the bytes take. Any Infinity-Fabric-level advantage of the
bridged pair (if one exists via this route) is not visible at this
granularity.

### Host ↔ GPU (shared buffers, totals incl. CPU pass)

| Direction | 32 MiB | 64 MiB |
|---|---|---|
| host → dev0 (memset + GPU read) | 4.8 GB/s | 5.4 GB/s |
| dev0 → host (GPU fill + CPU read) | 9.8 GB/s | 6.1 GB/s |

### Metal API overhead (mtl-bench, first device)

| Benchmark | ns/op | Note |
|---|---|---|
| commandBuffer.alloc | 2 110 | |
| commandBuffer.commit (empty) | 10 511 | pipelined |
| blitEncoder create+end | 3 399 | incl. CB alloc |
| blit.copy 64 B | 16 449 | one copy per CB |
| blit.copy 1 MiB | 11 903 (88 GB/s) | pipelined commits |
| renderPass setup (64×64 clear) | 14 258 | no draws, no commit |
| kernel dispatch (encode only) | 875 | 1×1, one CB |
| kernel dispatch (encode+commit) | 27 024 | pipelined commits |

## Raw data

- `raw/2026-09-11-w6800x-duo-copy-paths.json` (291 rows)
- `raw/2026-09-11-w6800x-duo-crosscard-peer.json` (peer sweep, dev0↔dev2)
- `raw/2026-09-11-w6800x-duo-api-overhead.json`
- Environment block: `gpu-probe --json` (same session)

## Conclusions

- **Metal on this driver exposes no direct GPU→GPU copy path**: cross-device
  movement goes through an IOSurface staging region with a per-hop
  commit/wait. End-to-end A→B reached ~8.5 GB/s, and the measured route
  shows no bandwidth difference between the same-module and the bridged
  cross-card pair — the cross-card Infinity Fabric Link bridge brings no
  measurable benefit to the staging route on this driver/OS.
- **Staging is not host-resident.** Read-out rates of 79–101 GB/s are far
  above the PCIe Gen3 x16 ceiling (~13 GB/s effective), so the driver places
  IOSurface pages in GPU memory and serves remote reads over the interconnect
  — the exact placement and the role of the xGMI hive are not observable via
  the API and remain to be confirmed with captures.
- Write-direction hop rates (22–26 GB/s) also exceed the PCIe ceiling;
  posted-write effects may inflate them.
- Command-buffer commit on this stack costs ~10 µs (empty, pipelined) and a
  committed 1×1 dispatch ~27 µs: latency-sensitive multi-GPU designs should
  batch heavily (the 170–407 µs peer hop latency is mostly submit/retire, not
  data movement).
- High variance at some sizes (local kernel path, host path) — re-run with
  clock control before quoting single points. `docs/metal/gotchas.md` records
  driver traps found while building these tools.
