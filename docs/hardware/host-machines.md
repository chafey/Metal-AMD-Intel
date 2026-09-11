# Host Machines

Intel Macs that can host MPX cards, their PCIe topology, and macOS support.

## Mac Pro (2019, Intel)

- Six PCI Express slots: slots 1–2 and 5–6 are double-width, slots 3–4 are
  quad-width (physically); electrically each full-length slot provides PCIe 3.0
  x16.
- MPX modules install in the double- or quad-width positions; power and
  thermal delivery are handled by the chassis.
- TODO: document per-slot PCIe lane routing (which CPU each slot attaches to
  on the dual-socket Xeon W parts) and how 3- vs 4-card configurations share
  bandwidth — capture with `system_profiler SPPCIExpressDataType` and
  `iokit-dump`.

## iMac Pro (2017, Intel)

- Vega II / Vega II Duo only, factory-installed (not user-serviceable).
- TODO: document how the Duo's two dies are wired to the platform in this
  chassis.

## macOS support matrix

| macOS | MPX support | Notes |
|---|---|---|
| 14 Sonoma | yes | our minimum build/run target |
| 15 Sequoia | yes | TODO: verify MPX kext/IOAccelerator status |
| 26+ | officially dropped Intel Macs | stock support ended after Sequoia; TODO: document what does/doesn't work on later macOS via unsupported paths (OCLP etc.) |

TODO: fill in exact IOAccelerator/Metal framework versions per OS release,
captured via `gpu-probe`'s environment section.

## Related

- [mpx-cards.md](mpx-cards.md)
- [../metal/gotchas.md](../metal/gotchas.md)
