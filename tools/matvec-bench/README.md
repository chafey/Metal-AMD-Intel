# matvec-bench

Measures the **compute** half of the batch-amortization trade-off.

`tp-sim` shows that batching B tokens into one all-reduce amortizes the
driver's fixed per-remote-op charge (20–24× less comm per token at B=32).
That win is only real if the *local* work per forward doesn't grow as
fast — and it eventually does, because one forward must do 2·K·N·B
FLOPs against K·N weights read once. This tool finds where the switch
happens on a single die.

## What it runs

| probe | what it bounds |
|---|---|
| `streamRead` | pure weight streaming — the memory-bound asymptote (~450–500 GB/s here) |
| `fmaPeak` | register-only FMA — the compute-bound asymptote (~9.2–10 TFLOPS fp32) |
| `mvB1…mvB64` | real dot-product kernel `D[N,B] += Σ_k W[K,N]·X[K,B]`, templated over B |

Their ratio predicts the knee: **B\* ≈ FMA/BW ≈ 20 tokens** on the
W6800X Duo. Measured: 3.1 ms/GB at B=1 → 3.4 at B=8 → 3.8 at B=16 → 5.5
at B=32, then a cliff (18 ms/GB at B=64 as the accumulator set exhausts
registers). Up to ~B=16 batching is essentially free on the compute
side; at 32 it costs ~1.8×; at 64 the naive per-thread kernel falls off
a cliff and needs tiling.

Multiply ms/GB by the weights resident on each die to get real compute
time: **10 GB/die (70B class, TP4) costs ~32 ms/forward at B=1 and ~35 ms
at B=8** — well under the measured comm time of 95–109 ms, which is why
batching wins. Results:
[`../../docs/benchmarks/raw/2026-09-12-matvec-bench-d1.json`](../../docs/benchmarks/raw/2026-09-12-matvec-bench-d1.json),
[`…-d3.json`](../../docs/benchmarks/raw/2026-09-12-matvec-bench-d3.json),
[`…-d1-8gib.json`](../../docs/benchmarks/raw/2026-09-12-matvec-bench-d1-8gib.json).

## Usage

```
swift build --package-path tools -c release --disable-sandbox --product matvec-bench
tools/.build/release/matvec-bench [--device N] [--gib GB] [--batches 1,2,4,8,16,32,64]
                                  [--slices K_SLICES] [--json]
```

- `--device` — Metal index; **device 0 (display GPU) is refused**.
- `--gib` — weight-matrix volume, default 2 GiB (8 GiB verified to agree).
- `--batches` — token counts to sweep, 1..64.
- `--slices` — how K is split across the grid (atomically reduced); default 32.

The B=64 result is a property of this deliberately naive kernel (one
thread per output column, B accumulators), not the hardware: it marks
where an untuned kernel needs shared-memory tiling, not where the GPU
runs out of FLOPs. Use B≤32 for engine sizing decisions.
