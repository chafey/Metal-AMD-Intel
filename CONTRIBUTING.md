# Contributing

## Ground rules

- **Docs carry the findings; code carries the proof.** A claim about hardware
  behavior in `docs/` should link to a tool invocation, example, or raw output
  that demonstrates it.
- **Degrade gracefully.** Tools must build and run (in a reduced mode) on any
  Mac from macOS 14+, even without an MPX card. MPX/Infinity-Fabric-specific
  output must be clearly flagged as such.
- **Minimum target is macOS 14** for all Swift and C/C++ code.

## Adding a benchmark report

1. Copy [docs/benchmarks/TEMPLATE.md](docs/benchmarks/TEMPLATE.md) to
   `docs/benchmarks/YYYY-MM-DD-<card>-<topic>.md`.
2. Run the relevant tool with the exact flags recorded in the report; paste the
   tool's JSON output into an appendix or a linked file next to the report.
3. Include machine details from `gpu-probe` output (machine model, macOS
   version, card(s), slot placement).

## Code layout

- Swift tools and examples live in the single SwiftPM package at `tools/Package.swift`
  (tools) and are organized per-example under `examples/swift/`.
- C/C++ artifacts use CMake under their own directories and are wired into the
  root `Makefile`.
- Format Swift with `swift-format` and C/C++ with `clang-format` (configs at
  repo root); CI checks both.

## Pull requests

Keep PRs scoped: one document set, one tool, or one example at a time. CI must
pass (compile + format + markdown lint); hardware validation is noted in the
PR description when it was performed.
