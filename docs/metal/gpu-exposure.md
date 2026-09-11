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
  `InfinityFabricLinks=1`, `XGMI_HiveSize=4`, and `XGMI_NodeIndex` 0…3 —
  one hive spanning both cards with one node per die. Node index does not
  map monotonically to anything Metal exposes; correlate per device via
  `registryID`.
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

MPX parts are not identical to their retail brothers (e.g. W6800X vs retail
W6800). TODO: tabulate feature-set differences observed via
`MTLDevice` capability checks (`supportsFamily:`, `supportsFeatureSet:`,
max threadgroup memory, GPU tiers).

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
