# mtl-bench

C++ (Objective-C++) microbenchmarks for Metal API overhead on MPX GPUs:

- command buffer alloc and empty-commit cost
- blit encoder create/end cost
- small blit copies (64 B – 1 MiB), one copy per command buffer
- render pass setup cost (64×64 clear attachment, no draws)
- kernel dispatch cost (encode-only vs encode+commit)

**Status:** implemented (Phase 3).

```
make ccpp
build/tools/mtl-bench/mtl-bench          # human summary
build/tools/mtl-bench/mtl-bench --json   # JSON on stdout (progress on stderr)
build/tools/mtl-bench/mtl-bench --device 3 --json   # MTLCopyAllDevices()[3]
```

## Note on Metal-cpp

The Phase 1 design said "uses Metal-cpp". That package ships only as an
Apple-ID-gated download, which CI cannot depend on, so the tool uses the
system `<Metal/Metal.h>` headers from Objective-C++ translation units
instead. The measured API surface is identical.

## Build notes

- Default build type is **Release**: with no optimization, the
  command-buffer allocation loop was observed to stall on the W6800X Duo /
  macOS 26.6.2 driver (see `docs/metal/gotchas.md`).
- `options:` parameters take *shifted* storage modes
  (`MTLResourceStorageModePrivate`), not bare `MTLStorageMode*` values —
  the driver asserts otherwise.

First results: `docs/benchmarks/2026-09-11-w6800x-duo-copy-paths.md`
("Metal API overhead" section).
