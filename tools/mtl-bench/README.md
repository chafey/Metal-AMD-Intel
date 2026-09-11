# mtl-bench

C++ microbenchmarks for Metal API overhead on MPX GPUs:

- kernel dispatch latency and throughput
- blit encoder copy throughput at small/fixed sizes
- render pass setup cost
- command buffer commit/retain cost

**Status:** planned (Phase 3). Uses Metal-cpp; builds via CMake from the root
`Makefile`. Emits the same JSON schema as the other tools so results drop into
`docs/benchmarks/` reports.
