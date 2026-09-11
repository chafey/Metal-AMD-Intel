# if-bench

Measures bandwidth and latency across the memory paths that matter on MPX
hosts: local VRAM, cross-device via IOSurface staging, and host↔GPU over
PCIe, with a concurrent-load mode as repro for co-scheduling issues.

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
| peer | device A ↔ device B | via one IOSurface staging region with a texture view per device — Metal has no direct GPU→GPU copy API; a coherence gate (write on A, read on B) runs first and peer rows are dropped if it fails |
| host | CPU ↔ device | `storageModeShared` buffers (host RAM on Intel); totals include the CPU pass — an approximation, labelled as such in output |
| concurrent | both devices local at once | vs. each alone; repro for co-scheduling stalls (`docs/metal/gotchas.md`) |

Bandwidth is pipelined (many copies per command buffer); latency uses
dependent copy chains. Sizes sweep 4 KiB → 64 MiB by default (`--min-size`
/ `--max-size`; the sweep auto-caps at half of
`recommendedMaxWorkingSetSize`). `--path blit|kernel|both`,
`--mode bw|latency|peer|host|concurrent|all` (comma-separated list allowed).
`--device-b` is optional: without it, `bw`/`latency`/`host` run on
`--device-a` only, while `peer`/`concurrent` are skipped with a note.
`scripts/run-all-benchmarks.sh` uses this to sweep every device
individually, then every device pair for peer.

## Interpreting peer numbers

Peer transfers are **two hops** (A→staging, staging→B) plus a commit/wait
per hop. The API does not reveal where staging pages physically live; on
the 2026-09-11 capture (`docs/benchmarks/2026-09-11-w6800x-duo-copy-paths.md`)
read rates far exceeded the PCIe ceiling, so the driver evidently does not
keep them in host RAM — but attributing traffic to the Infinity Fabric
Link jumper/bridge from these numbers alone is not sound. The tool reports
"best cross-device path available to Metal", not raw link bandwidth.

## Original measurement matrix (from Phase 1 design)

1. host → partition A / host → partition B (PCIe inbound) — `--mode host`
2. partition A ↔ partition B (on-module Infinity Fabric Link jumper) —
   approximated by `--mode peer` (staging route; no direct API exists)
3. partition A ↔ partition A (local baseline) — `--mode bw`
4. cross-card over the Infinity Fabric Link bridge — pair cards with
   `--device-a/--device-b`; label the pair's slot/hive info from
   `--list-devices` in the report
5. cross-card without bridge (host fallback) — same pairing, host route
