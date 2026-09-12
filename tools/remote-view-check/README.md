# remote-view-check

Ground-truth correctness + bandwidth test for **compute-kernel reads of
peer-group remote buffer views** (`newRemoteBufferViewForDevice:`).

On this driver kernel reads of remote views are *not* uniformly coherent:
loads must use naturally aligned types — `uint`, `ulong`, `float`,
`uint4`/`ulong2`/`float4` are coherent at every size and across producer
rewrites, while `uchar4` (16 B but only 4-byte aligned) is served from a
non-snooped cache and returns **stale data at fake local speed** even
after the producer's command buffer completed. Blit copies are always
correct. When coherent, kernel pulls match the copy engine (~23–29 GB/s)
— kernel reads are not a fast path. See
[gotchas](../docs/metal/gotchas.md).

Sections:

- **big** — 1 GiB remote view, full-grid copy at several vector widths
  (including the intentionally-broken `uchar4` row), 3 producer-rewrite
  rounds each, head/mid/tail spot checks, timed.
- **small** — 16 MiB, same matrix, full CPU verification of every word.

```
swift build --package-path tools -c release --disable-sandbox --product remote-view-check
tools/.build/release/remote-view-check [--small-only]
```

Run this after ANY change to kernels that read remote views — it is the
staleness gate for the tp-sim / if-bench kernel paths.
Raw: [`../../docs/benchmarks/raw/2026-09-12-remote-view-check.txt`](../../docs/benchmarks/raw/2026-09-12-remote-view-check.txt)
