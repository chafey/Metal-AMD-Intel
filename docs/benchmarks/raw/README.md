# Raw benchmark data

One file per run; filenames are `YYYY-MM-DD-<tool>-<variant>.(json|txt)`.
Each file is the unmodified stdout of the exact command recorded in the
corresponding report's "Exact commands" section.

## Do-not-cite files (known-bad measurements)

These raw files were produced by `a2a-bw --engine kernel` while the
kernel engine loaded remote buffer views with the misaligned `uchar4`
type. Misaligned 16-byte loads of remote views are served stale from a
non-snooped cache, so every bandwidth number in these files measures
cache, not the fabric. Retained solely as artefacts of the bug
(see `docs/metal/gotchas.md` and the banner in
`docs/benchmarks/2026-09-12-w6800x-duo-kernel-vs-blit-ceiling.md`):

- `2026-09-12-a2a-bw-kernel.json`
- `2026-09-12-a2a-bw-kernel-big.json`
- `2026-09-12-a2a-bw-kernel-nocache.json`
- `2026-09-12-a2a-bw-kernel-2gib-pair.json`
- `2026-09-12-a2a-bw-kernel-1gib-fanout.json`
- `2026-09-12-a2a-bw-kernel-1gib-cap1.json`
- `2026-09-12-a2a-bw-kernel-1gib-cap2.json`

Valid kernel-engine data uses the corrected `uint4` engine and carries
`-fixed-` in the filename (`2026-09-12-a2a-bw-kernel-fixed-*.json`).
