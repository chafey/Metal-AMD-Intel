# References

Links to primary sources, related projects, and community findings.

## Apple

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
