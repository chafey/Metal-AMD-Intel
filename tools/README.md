# Tools

Diagnostic and benchmark tools. Swift tools live in this SwiftPM package; the
C tool (`iokit-dump`) and any C++ tools use their own CMake builds and are
driven from the root `Makefile`.

> **Status:** `gpu-probe` (Swift) and `iokit-dump` (C) are implemented.
> `if-bench` and `mtl-bench` are design stubs scheduled for Phase 3; see
> each tool's README.

| Tool | Language | Purpose |
|---|---|---|
| [gpu-probe](gpu-probe/) | Swift | Enumerate `MTLDevice`s + IOKit registry properties; paste-ready environment block for benchmark reports |
| [if-bench](if-bench/) | Swift | On-module Infinity Fabric Link jumper and cross-card Infinity Fabric Link bridge bandwidth/latency |
| [mtl-bench](mtl-bench/) | C++ | Command-encoder / dispatch microbenchmarks |
| [iokit-dump](iokit-dump/) | C | Raw IORegistry dump of GPU/PCI families for triage |

All tools emit JSON on `--json` (machine-readable, for
`docs/benchmarks/`) and a human summary by default, and must run on any Mac
from macOS 14+, degrading gracefully when no MPX card is present.

Build: `make tools` or `swift build --package-path tools`.
