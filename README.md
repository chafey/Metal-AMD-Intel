# Metal-AMD-Intel

Documentation, tools, and examples for using **AMD MPX graphics cards under Metal on Intel Macs**, with particular focus on the **Infinity Fabric Link jumper** (the connector joining the two GPUs on *one* module — Vega II Duo, W6800X Duo) and the **Infinity Fabric Link bridge** (the connector joining GPUs across *two* cards — e.g. W6800X Duo, W6900X, Vega II pairs).

> **Terminology (per Apple):** an **Infinity Fabric Link jumper** connects the
> two GPUs on *one module*; an **Infinity Fabric Link bridge** connects GPUs
> across *two cards*.

> This repository is documentation-first: the [docs](docs/) capture findings about
> these cards and how Metal exposes them, while [tools](tools/) and
> [examples](examples/) produce and demonstrate those findings. Every benchmark
> number in the docs links to the tool invocation that produced it.

## Supported-card matrix

### Single card configurations


| Card | GPU silicon | VRAM | Bandwidth | Infinity Fabric | xGMI hive |
|---|---|---|---|---|---|
| Radeon Pro Vega II | Vega 20 (1× die) | 32 GB HBM2 | 1 TB/s | – | – |
| Radeon Pro Vega II Duo | 2× Vega 20 | 2× 32 GB HBM2 | 1 TB/s per die | Infinity Fabric Link jumper | 1 hive × 2 nodes |
| Radeon Pro W5700X | Navi 10 (RDNA 1) | 16 GB GDDR6 | 448 GB/s | – | – |
| Radeon Pro W6800X | Navi 21 (RDNA 2) | 32 GB GDDR6 | 512 GB/s | – | – |
| Radeon Pro W6800X Duo | 2× Navi 21 | 2× 32 GB GDDR6 | 512 GB/s per die | Infinity Fabric Link jumper | 1 hive × 2 nodes |
| Radeon Pro W6900X | Navi 21 (RDNA 2) | 32 GB GDDR6 | 512 GB/s | – | – |

### Multi-card configurations

An **Infinity Fabric Link bridge** connects GPUs across two MPX cards, joining
them into one xGMI hive and giving direct GPU-to-GPU peer paths that bypass
the host. (The **Infinity Fabric Link jumper** is a separate, on-module
connector: it joins the two GPUs of a Duo module and is not a cross-card
option.)

| Configuration | GPU silicon | VRAM | Bandwidth | Infinity Fabric | xGMI hive |
|---|---|---|---|---|---|
| 2× Radeon Pro W6800X Duo, Link jumpers only | 4× Navi 21 | 4× 32 GB GDDR6 (128 GB) | 512 GB/s per GPU | cards **not** IF connected; jumper joins GPUs within each module | 2 hives × 2 nodes |
| 2× Radeon Pro W6800X Duo, Link bridge | 4× Navi 21 | 4× 32 GB GDDR6 (128 GB) | 512 GB/s per GPU | bridge joins the two module hives | 1 hive × 4 nodes |
| 2× Radeon Pro W6900X, Link bridge | 2× Navi 21 | 2× 32 GB GDDR6 (64 GB) | 512 GB/s per GPU | supported | 1 hive × 2 nodes |
| 2× Radeon Pro Vega II, Link bridge | 2× Vega 20 | 2× 32 GB HBM2 (64 GB) | 1 TB/s per GPU | supported | 1 hive × 2 nodes |
| 2× Radeon Pro Vega II Duo, Link jumpers only | 4× Vega 20 | 4× 32 GB HBM2 (128 GB) | 1 TB/s per GPU | cards **not** IF connected; jumper joins GPUs within each module | 2 hives × 2 nodes |
| 2× Radeon Pro Vega II Duo, Link bridge | 4× Vega 20 | 4× 32 GB HBM2 (128 GB) | 1 TB/s per GPU | ⚠️¹ | 1 hive × 4 nodes (unverified) |

> Without an Infinity Fabric Link bridge, cross-card traffic falls back to the
> PCIe host path.
> TODO: jumper/bridge part numbers, official supported-pairings list, link
> widths, and measured bandwidth
> (see [docs/hardware/infinity-fabric.md](docs/hardware/infinity-fabric.md)).
>
> ¹ Two Duo cards with an **Infinity Fabric Link jumper** on each module are
> not connected to each other via Infinity Fabric: the jumper only joins the
> GPUs *within* each module, and card-to-card traffic uses the PCIe host
> path. Whether the 2× Vega II Duo pairing may also be joined across cards
> with an **Infinity Fabric Link bridge** may not be a configuration Apple
> supports. TODO: confirm Apple's official supported configuration list for
> the bridged Vega II Duo pairing.

See [docs/hardware/mpx-cards.md](docs/hardware/mpx-cards.md) for details and
[docs/hardware/host-machines.md](docs/hardware/host-machines.md) for slot/lane information.

## Repository layout

```
docs/       Documentation: hardware, Metal behavior, dated benchmark reports
tools/      Benchmarks and diagnostic tools (Swift via SwiftPM, C/C++ via CMake)
examples/   Worked examples in Swift and C/C++
scripts/    Build and benchmark helper scripts
```

- [docs/](docs/) — start with [hardware/mpx-cards.md](docs/hardware/mpx-cards.md)
- [tools/](tools/) — start with [tools/gpu-probe](tools/gpu-probe)
- [examples/](examples/) — start with [examples/swift/device-basics](examples/swift/device-basics)

## Quickstart

```sh
# Build everything (requires Xcode 15+ and CMake)
make all

# Run the discovery tools
swift run --package-path tools gpu-probe
make ccpp && build/tools/iokit-dump/iokit-dump --name AMDRadeonX6000
swift run --package-path examples/swift device-basics

# (if-bench and mtl-bench land in Phase 3; their READMEs describe the
# planned interfaces)

# Run all benchmarks and drop JSON results in build/
./scripts/run-all-benchmarks.sh
```

Requires **macOS 14 or later** on the machines where tools are built and run.
CI only compiles and unit-tests; hardware measurements must be produced on
machines with the actual cards (see [.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Contributing

- Hardware findings go in `docs/` and should cite the tool + flags that produced them.
- New benchmark reports use [docs/benchmarks/TEMPLATE.md](docs/benchmarks/TEMPLATE.md) and
  are named `YYYY-MM-DD-<card>-<topic>.md`.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT — see [LICENSE](LICENSE).
