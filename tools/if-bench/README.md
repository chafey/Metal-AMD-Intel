# if-bench

Measures bandwidth and latency across the memory paths that matter on MPX
hosts: local VRAM, cross-device via IOSurface staging **or** peer-group P2P
(remote buffer views), and host↔GPU over PCIe, with a concurrent-load mode
as repro for co-scheduling issues.

**Status:** implemented (Phase 3).

```
swift run --package-path tools if-bench              # human summary
swift run --package-path tools if-bench -- --json    # machine-readable
swift run --package-path tools if-bench -- --list-devices
```

## What it measures

| Direction | Path | Notes |
|---|---|---|
| local | device → own VRAM | blit **and** kernel copy paths; baseline |
| peer | device A ↔ device B | via one IOSurface staging region with a texture view per device (two hops); a coherence gate (write on A, read on B) runs first and peer rows are dropped if it fails |
| p2p | device A ↔ device B | peer-group **pull**: the reader's own queue copies a read-only `newRemoteBufferViewForDevice:` view of the peer's private VRAM into its own — one hop, no IOSurface; requires a shared non-zero `peerGroupID` (the xGMI hive), gated by a changing-pattern coherence check both directions |
| host | CPU ↔ device | `storageModeShared` buffers (host RAM on Intel); totals include the CPU pass — an approximation, labelled as such in output |
| concurrent | both devices local at once | vs. each alone; repro for co-scheduling stalls (`docs/metal/gotchas.md`) |

Bandwidth is pipelined (many copies per command buffer); latency uses
dependent copy chains. Sizes sweep 4 KiB → 64 MiB by default (`--min-size`
/ `--max-size`; the sweep auto-caps at half of
`recommendedMaxWorkingSetSize`). `--path blit|kernel|both`,
`--mode bw|latency|peer|host|concurrent|all` (comma-separated list allowed).
`--peer-path p2p|blit|kernel|both|all` selects the implementation for peer
mode (**default `p2p`** — peer-group remote buffer views, the fastest route
within a hive, skipped with a note outside one; `blit`/`kernel` are the
two-hop IOSurface staging route, the fallback for pairs with no shared peer
group and for push-style sharing; `both` = blit+kernel staging, `all` =
those + p2p; each path gets its own coherence gate; latency rows are
blit-only). On the 2026-09-11 capture
kernel hops move ~8× more
bytes in isolation, but within one xGMI hive the two-hop chain plateaus at
~11 GB/s either way — the ceiling is the cross-device staging step, not
the hop engine. Cross-hive pairs (e.g. hive member ↔ plain-PCIe GPU) stay
at ~3 GB/s with either hop implementation; see `docs/metal/gotchas.md`.
`p2p` rows bypass staging entirely and plateau at 36.9–38.5 GB/s for both
jumper and bridge pairs; they are skipped with a note when the devices do
not share a non-zero `peerGroupID`.
`--device-b` is optional: without it, `bw`/`latency`/`host` run on
`--device-a` only, while `peer`/`concurrent` are skipped with a note.
`scripts/run-all-benchmarks.sh` uses this to sweep every device
individually, then every device pair for peer.

## Interpreting peer numbers

IOSurface peer transfers are **two hops** (A→staging, staging→B) plus a
commit/wait
per hop. The API does not reveal where staging pages physically live; on
the 2026-09-11 capture (`docs/benchmarks/2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md`)
read rates far exceeded the PCIe ceiling, so the driver evidently does not
keep them in host RAM — but attributing traffic to the Infinity Fabric
Link jumper/bridge from these numbers alone is not sound. Those rows report
"best staging-route bandwidth", not raw link bandwidth.

`p2p` rows (staging-free pulls) move **one hop**: bytes = buffer size, and
the seconds value is per single pull, so p2p and per-hop staging rows are
directly comparable. The coherence gate reseeds the source with a
*different* changing pattern each round and verifies in both directions —
repeated pulls of identical bytes would pass even if the reader's caches
served stale lines. Remote views are read-only on the AMDRadeonX6000
driver, so the destination-side pull direction is mandatory (see
`docs/metal/gotchas.md`).

## Original measurement matrix (from Phase 1 design)

1. host → partition A / host → partition B (PCIe inbound) — `--mode host`
2. partition A ↔ partition B (on-module Infinity Fabric Link jumper) —
   `--mode peer` (default: direct peer-group pull, one hop) and
   `--mode peer --peer-path blit` (IOSurface staging route, two hops)
3. partition A ↔ partition A (local baseline) — `--mode bw`
4. cross-card over the Infinity Fabric Link bridge — pair cards with
   `--device-a/--device-b`; label the pair's slot/hive info from
   `--list-devices` in the report
5. cross-card without bridge (host fallback) — same pairing, host route
