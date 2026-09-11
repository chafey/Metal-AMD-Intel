# iokit-dump

Small C utility that walks the IORegistry from the `IOPCIDevice` / GPU service
roots and dumps properties (including binary blobs like `ATY,bin_image`
metadata summaries) for triage and for building the property tables in
`docs/hardware/mpx-cards.md`.

**Status:** planned (Phase 2). Builds via CMake from the root `Makefile`.
Complements `ioreg -alc` by filtering to GPU-relevant subtrees and decoding
the numeric properties (device ids, link widths) into readable form.
