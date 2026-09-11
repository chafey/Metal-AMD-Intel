# iokit-dump

Small C utility that walks the IORegistry from the `IOPCIDevice` roots and
dumps properties (including binary blobs, shown as byte counts / hex
previews) for triage and for building the property tables in
`docs/hardware/mpx-cards.md`.

**Status:** implemented (Phase 2).

Build and run:

```
cmake -S tools/iokit-dump -B build/tools/iokit-dump
cmake --build build/tools/iokit-dump
build/tools/iokit-dump/iokit-dump --name AMDRadeonX6000
```

(or `make ccpp` from the root `Makefile`.)

## Usage

```
iokit-dump [options]
  --all          include non-GPU PCI devices (default: GPU-related only)
  --json         nested JSON output instead of the text tree
  --name STR     keep nodes whose class or service name contains STR
  --key  STR     keep nodes that have a property whose name contains STR
  --blob         show full hex for binary properties (default: preview)
  -h, --help
```

Every node line includes its registry-entry id (`[id=0x...]`), which is what
`MTLDevice.registryID` matches — use it to find the node behind a Metal
device. Numeric-looking properties stored as little-endian `Data` blobs
(`device-id`, `vendor-id`, ...) are decoded to hex numbers.

Complements `ioreg -alc` by filtering to GPU-relevant subtrees and decoding
the numeric properties (device ids, link widths) into readable form.
