# gpu-probe

Enumerates every `MTLDevice` and its backing IOKit registry properties, plus
machine/OS/driver environment, in a form that can be pasted directly into a
benchmark report (see `docs/benchmarks/TEMPLATE.md`).

**Status:** implemented (Phase 2).

```
swift run --package-path tools gpu-probe          # human summary
swift run --package-path tools gpu-probe -- --json # machine-readable
```

## What it reports

- **Environment**: model, CPU + core count, RAM, macOS version/build/arch,
  and the versions of the loaded AMD driver bundles/kexts
  (`AMDRadeonX6000*`, `AMDRadeonVADriver*`, ...).
- **Per `MTLDevice`**: name, `registryID`, `recommendedMaxWorkingSetSize`,
  supported GPU families and highest supported feature set. Family and
  feature-set checks are done by raw value via `supportsFamily:` /
  `supportsFeatureSet:` so the tool keeps working when an SDK removes enum
  cases (macOS 26's SDK removed `MTLDevice.location`/`entryPoint` and several
  `MTLFeatureSet` cases this way).
- **Metal ↔ IOKit correlation**: `MTLDevice.registryID` equals the IOKit
  registry-entry id (`IORegistryEntryGetRegistryEntryID`) of the device's
  accelerator service node; the tool walks up to the backing
  `IOPCIDevice` function.
- **Per backing `IOPCIDevice`**: `vendor-id`, `device-id`, `revision-id`,
  `subsystem-vendor-id`, `subsystem-id`, `class-code`, `AAPL,slot-name`, and
  the negotiated PCIe link decoded from `IOPCIExpressLinkStatus`
  (bits 0-3 speed, bits 4-9 width — e.g. `0x7104` = 16 GT/s x16).
- **xGMI / Infinity Fabric**: scans the GPU function's subtree for
  `InfinityFabricLinks`, `XGMI_Enabled`, `XGMI_HiveSize`, `XGMI_NodeIndex`.
- **Duo-partition correlation**: Metal devices backed by the same
  `IOPCIDevice` function are reported as one physical module. (On systems
  where each die exposes its own PCI function — as observed on a 2× W6800X
  Duo machine — no pairs are reported; the per-function PCI data is still
  per-die.)

## Notes / TODO

- `*-id` registry properties are little-endian `Data` blobs, not numbers;
  the tool decodes them accordingly.
- `IOPCIExpressLinkStatus` is decoded per PCIe r3.0 §7.5.3.19; speeds above
  Gen5 are not yet mapped.
- The exact semantics of `XGMI_NodeIndex` (per-die within the hive vs. per
  card) should be confirmed with captures from more hive shapes (e.g. a
  bridge-connected 2× single-GPU-card configuration).
- `--json` renders binary properties as a byte-count plus hex preview.
