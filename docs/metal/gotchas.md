# Metal Gotchas on MPX / Intel Hosts

A running log of driver, IOAccelerator, and OS-level surprises. Each entry:
symptom, affected configuration, workaround, and OS/driver version observed.

## Template for new entries

```md
### <short title>
- **Affects:** <card(s)>, macOS x.y, IOAccelerator kext version
- **Symptom:** what you see
- **Repro:** minimal case or tool invocation
- **Workaround:** what works
- **Status:** workaround-only / fixed in x.y / filed with Apple
```

## Known issues

### Host writes to `MTLStorageModePrivate` buffer contents stall submissions
- **Affects:** W6800X Duo, macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** `buffer.contents().copyMemory(...)` on a private-storage
  buffer appears to succeed, but the next command-buffer completion hangs
  indefinitely (`waitUntilCompleted` never returns); the GPUs survive
  process kill
- **Repro:** create a `.storageModePrivate` buffer, write through
  `contents()`, blit it, `waitUntilCompleted()`
- **Workaround:** use `.storageModeShared` (host-visible) buffers for
  anything the CPU initializes or reads back (that is what `if-bench` does)
- **Status:** workaround-only

### `options:` parameter takes shifted storage modes, not `MTLStorageMode*`
- **Affects:** all AMD MPX parts, macOS 26.6.2 (driver assertion text is
  driver-side); same API contract on all macOS
- **Symptom:** `[device newBufferWithLength:options:MTLStorageModePrivate]`
  aborts with `failed assertion 'Invalid cacheMode 2'`
- **Repro:** mtl-bench history — passing the unshifted enum as resource
  options; Swift's `.storageModePrivate` is already shifted, which is why
  Swift code does not trip it
- **Workaround:** `MTLResourceStorageModePrivate`, i.e. `(MTLResourceOptions)
  MTLStorageModePrivate << MTLResourceStorageModeShift`
- **Status:** workaround-only (API misuse, but the failure mode is an opaque
  driver assert rather than a validation error)

### Accumulated uncommitted command buffers stall command-buffer allocation
- **Affects:** W6800X Duo, macOS 26.6.2, AMDRadeonX6000 7.0.1
- **Symptom:** creating command buffers without ever committing them leaks
  (ARC off, autorelease pool drained late, or driver-side retention) and
  `[queue commandBuffer]` eventually blocks forever; observed within a
  20 000-buffer loop when buffers were not released, and — less reliably —
  in a non-optimized (`-O0`) build of an otherwise-identical ARC loop
- **Repro:** compile a loop of `[queue commandBuffer]` without `-fobjc-arc`
  (or with a late autorelease pool); completes with ARC + `-O2`
- **Workaround:** release or commit each command buffer; keep benchmarks
  optimized (`CMAKE_BUILD_TYPE=Release`, now the default in
  `tools/mtl-bench/CMakeLists.txt`)
- **Status:** workaround-only; root cause (driver retention vs pool timing)
  not established

### IOSurface staging route across the xGMI hive boundary collapses
- **Affects:** W6800X Duo (xGMI hive of 4) + RX 6900 XT (plain PCIe),
  macOS 26.6.2, IOAcceleratorFamily2 487.4.3 / AMDRadeonX6000 7.0.1
- **Symptom:** cross-device IOSurface staging transfers between an
  xGMI-hive GPU and a non-hive GPU reach only 1.6–3.7 GB/s end-to-end
  (vs 8.6–8.9 GB/s between hive members) even though each single hop
  measures normally in isolation; direction-asymmetric (to the non-hive
  card is slower) and dependent-chain latency is unstable (343–5 744
  µs/hop vs ~120–160 µs/hop within the hive). Switching the hop
  implementation to a compute kernel (`--peer-path kernel`) does not
  improve it — the penalty sits at the hive boundary, not the hop engine
- **Repro:** `swift run --package-path tools if-bench -- --device-a <hive-die>
  --device-b <non-hive-gpu> --mode peer --json` (see
  `docs/benchmarks/2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md`)
- **Workaround:** keep IOSurface-based cross-device sharing inside one
  xGMI hive; for hive↔non-hive movement budget PCIe-class bandwidth and
  batch heavily, or stage via host memory explicitly
- **Status:** observed, mechanism not established (staging page placement
  is not observable via the API)

### (placeholder) Duo partition co-scheduling stalls
- **Affects:** W6800X Duo, macOS 14.x — TODO: confirm
- **Symptom:** TODO: describe observed stalls when both partitions run heavy
  concurrent workloads
- **Repro:** `tools/if-bench --mode concurrent-load`
- **Workaround:** TODO
- **Status:** investigating

> Replace this placeholder with verified findings only; each entry must be
> reproducible with a checked-in tool or example.
