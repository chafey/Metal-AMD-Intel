# Benchmark Reports

Dated measurement reports, one file per run:
`YYYY-MM-DD-<card>-<topic>.md`, created from [TEMPLATE.md](TEMPLATE.md).
Every number in `docs/` must link to a report here, and every report links
to the tool + exact command and the raw JSON in [raw/](raw/).

| Date | Report | Tool |
|---|---|---|
| 2026-09-11 | [2× W6800X Duo — copy paths and API overhead](2026-09-11-w6800x-duo-copy-paths.md) | `if-bench`, `mtl-bench` |
| 2026-09-11 | [2× W6800X Duo + RX 6900 XT — full device matrix](2026-09-11-6900xt-plus-w6800x-duo-full-matrix.md) | `if-bench`, `mtl-bench` (all-GPU matrix) |

Reproduce on MPX hardware with `./scripts/run-all-benchmarks.sh` (JSON
lands in `build/results/`).
