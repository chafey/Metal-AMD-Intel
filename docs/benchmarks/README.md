# Benchmark Reports

Dated measurement reports, one file per run:
`YYYY-MM-DD-<card>-<topic>.md`, created from [TEMPLATE.md](TEMPLATE.md).
Every number in `docs/` must link to a report here, and every report links
to the tool + exact command and the raw JSON in [raw/](raw/).

| Date | Report | Tool |
|---|---|---|
| 2026-09-11 | [2× W6800X Duo — copy paths (p2p, staging, local, host) and API overhead](2026-09-11-w6800x-duo-copy-paths.md) | `if-bench` (p2p default + staging), `mtl-bench` |
| 2026-09-11 | [2× W6800X Duo — peer-group P2P pull matrix (all 6 die pairs)](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md) | `if-bench` (default p2p route) |
| 2026-09-12 | [2× W6800X Duo — llama.cpp-style TP-4 decode all-reduce simulation](2026-09-12-w6800x-duo-tp-decode-sim.md) | `tp-sim`, `pull-contention` |
| 2026-09-12 | [2× W6800X Duo — is bridge bandwidth shared across simultaneous flows?](2026-09-12-w6800x-duo-bridge-share.md) | `a2a-bw` |
| 2026-09-12 | [2× W6800X Duo — the ~90 GB/s ceiling is the blit engine, not the fabric](2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md) | `a2a-bw` v2 (`--engine kernel`, `--max-concurrent`) |

Captures are scoped to the two W6800X Duo modules; a third GPU (RX 6900
XT, display) is present in the machine listings but not measured. All
superseded captures — including the 2026-09-11 runs that measured the
6900 XT — remain recoverable from git history.

Reproduce on MPX hardware with `./scripts/run-all-benchmarks.sh` (JSON
lands in `build/results/`).
