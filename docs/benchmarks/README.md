# Benchmark Reports

Dated measurement reports, one file per run:
`YYYY-MM-DD-<card>-<topic>.md`, created from [TEMPLATE.md](TEMPLATE.md).
Every number in `docs/` must link to a report here, and every report links
to the tool + exact command and the raw JSON in [raw/](raw/).

| Date | Report | Tool |
|---|---|---|
| 2026-09-11 | [2× W6800X Duo — copy paths and API overhead](2026-09-11-w6800x-duo-copy-paths.md) | `if-bench`, `mtl-bench` |

Reproduce on MPX hardware with `./scripts/run-all-benchmarks.sh` (JSON
lands in `build/results/`).
