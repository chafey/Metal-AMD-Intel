# How Metal Exposes MPX GPUs

Notes on `MTLCopyAllDevices()` output, device naming, and the quirks of
Duo-card partitions on MPX hosts.

## Device enumeration

Observed on Mac Pro (2019), macOS 26.6.2 (25G83), 2026-09-11 (`gpu-probe` scaffold):
**four** `MTLDevice`s are enumerated, all named `"AMD Radeon PRO W6800X Duo"`,
with distinct `registryID`s that exceed `UInt32.max` (e.g. 4294970790 ⇒
`0x1_0000_0DA6`) — so the SDK exposes `registryID` as `UInt64` and it must not
be narrowed to 32 bits.

TODO: correlate the four devices with physical modules/partitions via
`location`/`entryPoint` and IOKit parent `IOPCIDevice`s (full `gpu-probe`
implementation in Phase 2).

TODO: paste authoritative `gpu-probe` output for each configuration and
annotate it. Questions this document must answer:

- Does a W6800X Duo appear as one `MTLDevice` or two? What are the device
  strings in each case?
- How do the two partitions of a Duo card report `recommendedMaxWorkingSetSize`,
  `registryID`, and `location` / `entryPoint`?
- How do two physical cards differ in enumeration from one Duo card?

## Capability differences vs. desktop AMD cards

MPX parts are not identical to their retail brothers (e.g. W6800X vs retail
W6800). TODO: tabulate feature-set differences observed via
`MTLDevice` capability checks (`supportsFamily:`, `supportsFeatureSet:`,
max threadgroup memory, GPU tiers).

## Multi-device behavior

Covered in [../../examples/swift/multi-gpu](../../examples/swift/multi-gpu):

- Command queues are per-device; synchronization across devices is explicit.
- TODO: document supported mechanisms for sharing `MTLBuffer`/`MTLTexture`
  content between two devices on the same Mac (shared-mode buffers,
  `MTLShareableSharedBufferManager`, IOSurface routes) and which of them work
  across a Duo card's IF bridge.

See [gotchas.md](gotchas.md) for driver-level surprises and
[tuning.md](tuning.md) for placement guidance.
