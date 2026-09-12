# How Metal Exposes MPX GPUs

Notes on `MTLCopyAllDevices()` output, device naming, and the quirks of
Duo-card partitions on MPX hosts.

## Device enumeration

Captured on Mac Pro (2019), macOS 26.6.2 (25G83), 2× Radeon Pro W6800X Duo,
2026-09-11, with `tools/gpu-probe -- --json`:

- **Four** `MTLDevice`s are enumerated, all named `"AMD Radeon PRO W6800X
  Duo"` — one per GPU die, not one per card.
- `registryID` exceeds `UInt32.max` (e.g. `0x1_0000_0DA6`): the SDK exposes
  it as `UInt64` and it must not be narrowed to 32 bits.
- **Metal ↔ IOKit correlation:** `MTLDevice.registryID` equals the IOKit
  registry-entry id (`IORegistryEntryGetRegistryEntryID`) of the device's
  accelerator service node (`AMDRadeonX6000_AMDNavi21GraphicsAccelerator`).
  Do **not** look for an "IORegistryID" property — it does not exist. The
  former `MTLDevice.location`/`entryPoint` APIs were removed in the macOS 26
  SDK, so `registryID` is the correlation key.
- Each of the four Metal devices correlates 1:1 with its own `IOPCIDevice`
  function named `GFX0` (one PCI function per die; two per Duo card). PCI
  ids per function: vendor `0x1002`, device `0x73ab`, subsystem
  `0x106b:0x0222`, class `0x030000`. PCIe link negotiates 16 GT/s (Gen 4)
  x16 (`IOPCIExpressLinkStatus = 0x7104`).
- **xGMI hive:** each `GFX0` function reports `XGMI_Enabled=1`,
  `InfinityFabricLinks=1` (a boolean "yes, IF-capable" — **not** a link
  count), `XGMI_HiveSize=4`, and `XGMI_NodeIndex` 0…3 —
  one hive spanning both cards with one node per die. Node index does not
  map monotonically to anything Metal exposes; correlate per device via
  `registryID`. The registry does **not** expose the physical wiring (which
  die's link connects to which).
- Per device: `recommendedMaxWorkingSetSize = 34,342,961,152` bytes
  (≈ 32 GiB, i.e. one die's VRAM, not the card's 64 GB).
- Families: `mac1`, `mac2`, `common1–3`, `metal3`. Feature sets reported
  supported: `macOS_GPUFamily1_v1–v4` and `macOS_GPUFamily2_v1` only —
  `GPUFamily2_v5/v6` are *not* reported as supported even though the newer
  `mac2`/`metal3` families are. Queries are done by raw value via
  `supportsFamily:`/`supportsFeatureSet:` (`gpu-probe`), independent of SDK
  enum availability.

Still open:

- How do two physical cards differ in enumeration from one Duo card? (All
  four devices here share one hive across two cards, which have an Infinity
  Fabric Link bridge fitted; a non-bridged pairing or a single Duo card
  should be captured for comparison.)
- `XGMI_NodeIndex` semantics across hive shapes (see `tools/gpu-probe/README.md`
  TODO).

## Capability differences vs. desktop AMD cards

Measured, not folklore: the reference machine carries both Navi 21 flavors —
MPX **W6800X Duo** (4 dies) and a retail **RX 6900 XT** (display card) —
under one driver stack (AMDRadeonX6000 7.0.1, macOS 26.6.2). Capture:
`tools/.build/release/gpu-probe --json` →
[`raw/2026-09-12-gpu-probe-caps.json`](../benchmarks/raw/2026-09-12-gpu-probe-caps.json).

| Probe (MTLDevice / pipeline) | W6800X Duo (per die) | RX 6900 XT | Δ |
|---|---|---|---|
| `supportsFamily:` | mac1, mac2, common1–3, metal3 | same | none |
| `supportsFeatureSet:` | GPUFamily1_v1–v4, GPUFamily2_v1 (max = GPUFamily2_v1) | same | none |
| `maxThreadgroupMemoryLength` | 65 536 B | 65 536 B | none |
| `maxBufferLength` | 3 758 096 384 B (~3.5 GiB) | same | none |
| max threads/threadgroup (device + pipeline) | 1024×1024×1024; wave 32 | same | none |
| Raster order groups / 32-bit float filtering / pull-model interpolation / vertex amplification | all supported | all supported | none |
| unified memory / low power | no / no | no / no | none |
| `recommendedMaxWorkingSetSize` | 34 342 961 152 B (≈32 GB) | 17 163 091 968 B (≈16 GB) | tracks VRAM |
| xGMI peer group (`peerGroupID`) | non-zero, hive of 4 | 0 (no peer) | **MPX + bridge only** |

**Takeaway:** on this driver stack the MPX W6800X exposes *no Metal
feature-level differences* vs the retail RX 6900 XT (same silicon family);
what the MPX + Infinity Fabric Link bridge configuration adds is the xGMI
peer group, and the retail-vs-MPX distinctions that matter (VRAM, ECC,
clocking, thermals) are not visible through `MTLDevice` capability checks.
Note the wave width: 32 (Navi wave32) — kernels tuned for wave64 will
underutilise these GPUs regardless of card type.

Caveat: the retail comparison part here is the RX 6900 XT, not the
workstation W6800; a W6800 capture could still add ECC/RDMA-adjacent
registry differences, though none are expected at the Metal API level.

## Multi-device behavior

Covered in [../../examples/swift/multi-gpu](../../examples/swift/multi-gpu):

- Command queues are per-device; synchronization across devices is explicit.
- Cross-device buffer sharing on this driver (verified 2026-09-11):
  the primary mechanism is the **peer group**: all devices in one xGMI hive
  share a non-zero `MTLDevice.peerGroupID`, and
  `MTLBuffer newRemoteBufferViewForDevice:` (public macOS 10.15+ API) hands
  a peer a **read-only** view of a private VRAM buffer. Transfers are
  destination-side pulls on the reader's own queue; both directions of an
  A↔B exchange are two pulls. Works across the Infinity Fabric Link jumper
  and the cross-card Infinity Fabric Link bridge alike (both are inside one
  peer group); devices outside the hive (`peerGroupID` 0) get nil views and
  must use IOSurface staging or host memory. Numbers:
  [p2p matrix report](../benchmarks/2026-09-11-w6800x-duo-p2p-peer-group-matrix.md).
  TODO: document `MTLShareableSharedBufferManager` and shared-mode buffers
  for the process-sharing case (not yet exercised here).

See [gotchas.md](gotchas.md) for driver-level surprises and
[tuning.md](tuning.md) for placement guidance.
