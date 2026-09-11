# mpsc-ring

C++ example: a multi-producer / single-consumer ring buffer driving GPU work,
used to measure steady-state throughput (dispatch cost amortized over a full
pipeline) rather than cold-start latency. Doubles as a harness pattern for
`mtl-bench`-style measurements.

**Status:** planned (Phase 4). Builds via CMake from the root `Makefile`.
