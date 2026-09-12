# Tools

Diagnostic and benchmark tools. Swift tools live in this SwiftPM package; the
C tool (`iokit-dump`) and any C++ tools use their own CMake builds and are
driven from the root `Makefile`.

> **Status:** `gpu-probe` (Swift), `if-bench` (Swift), `tp-sim` (Swift),
> `pull-contention` (Swift) and `iokit-dump` (C) are implemented, as is
> `mtl-bench` (C++). All six ran on MPX hardware; results live in
> [`../docs/benchmarks/`](../docs/benchmarks/).

| Tool | Language | Purpose |
|---|---|---|
| [gpu-probe](gpu-probe/) | Swift | Enumerate `MTLDevice`s + IOKit registry properties; paste-ready environment block for benchmark reports |
| [if-bench](if-bench/) | Swift | Local / cross-device (IOSurface staging **and** peer-group P2P remote views) / host copy bandwidth & latency; concurrent-load repro |
| [tp-sim](tp-sim/) | Swift | Simulates llama.cpp/toshllm Metal TP decode all-reduces over a peer group; event-chain vs serialised-pull vs CPU-barrier sync, with a cross-device correctness gate |
| [pull-contention](pull-contention/) | Swift | Isolates the driver's concurrent remote-view pull penalty (per-op cost, sequential-vs-concurrent, fan-in hang) |
| [mtl-bench](mtl-bench/) | C++ | Command-encoder / dispatch microbenchmarks |
| [iokit-dump](iokit-dump/) | C | Raw IORegistry dump of GPU/PCI families for triage |

All tools emit JSON on `--json` (machine-readable, for
`docs/benchmarks/`) and a human summary by default, and must run on any Mac
from macOS 14+, degrading gracefully when no MPX card is present.

Build: `make tools` or `swift build --package-path tools`.
