# References

Links to primary sources, related projects, and community findings.

## Apple

- Mac Pro (2019) — Technical Specifications —
  <https://support.apple.com/en-ge/118461> (accessed 2026-09-12) — states
  Infinity Fabric Link capacity: W6800X / W6900X "up to 84GB/s in each
  direction"; W6800X Duo onboard link same; external (bridge) connection
  described for four-GPU linking **without a bandwidth figure**; Vega II /
  Vega II Duo "up to 84GB/s" (direction convention unstated). Used by
  [hardware/infinity-fabric.md](hardware/infinity-fabric.md).
- Metal Family Recommendations — `MTLGPUFamily` docs for AMD tiers
- Metal Feature Set Tables — per-feature support on AMD GPUs
- `IOPCIDevice` / IOKit PCI Family Introductions — reading IORegistry properties
- macOS security guide / extension docs — context for kext & driver loading rules

TODO: replace with direct URLs and access dates.

## AMD

- RDNA 2 / GCN (Vega) whitepapers — architecture background for the underlying
  silicon (retail variants; MPX behavior differs)
- TODO: cite any public xGMI/Infinity Fabric documentation

## IOKit headers of interest

- `/System/Library/Extensions/AMDMTLBronzeDriver.bundle` and the AMD
  IOAccelerator kexts (inspect with `iokit-dump` and `ioreg`)
- TODO: list the specific registry keys that turn out to matter

## Community

- TODO: add high-quality community write-ups on MPX cards and Mac Pro 2019 GPU
  internals (elaborate before merging; prefer sources with reproducible data)

## Tooling prior art

- `gpuencode`, Geekbench/GPU profile reports — baselines people will compare
  our numbers against
