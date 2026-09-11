# Benchmark Reports

Dated measurement reports, one file per run:
`YYYY-MM-DD-<card>-<topic>.md`, created from [TEMPLATE.md](TEMPLATE.md).
Every number in `docs/` must link to a report here, and every report links
to the tool + exact command and the raw JSON in [raw/](raw/).

| Date | Report | Tool |
|---|---|---|
| 2026-09-11 | [2× W6800X Duo + RX 6900 XT — full device matrix (fresh capture)](2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md) | `if-bench` (p2p default + staging), `mtl-bench` |
| 2026-09-11 | [2× W6800X Duo — peer-group P2P pull matrix (all 6 die pairs)](2026-09-11-w6800x-duo-p2p-peer-group-matrix.md) | `if-bench` (default p2p route) |

Earlier 2026-09-11 captures (copy-paths report, debug-build matrix, addenda)
were replaced by a single clean idle-machine session; superseded files
remain recoverable from git history.

Reproduce on MPX hardware with `./scripts/run-all-benchmarks.sh` (JSON
lands in `build/results/`).
