# Metal-AMD-Intel

Documentation, tools, and examples for using **AMD MPX graphics cards under Metal on Intel Macs**, with particular focus on cards with an on-card **Infinity Fabric bridge** (Vega II Duo, W6800X Duo, W6900X).

> This repository is documentation-first: the [docs](docs/) capture findings about
> these cards and how Metal exposes them, while [tools](tools/) and
> [examples](examples/) produce and demonstrate those findings. Every benchmark
> number in the docs links to the tool invocation that produced it.

## Supported-card matrix

### Single card configurations


| Card | GPU silicon | VRAM | Host machines | Infinity Fabric |
|---|---|---|---|---|
| Radeon Pro Vega II | Vega 20 (1× die) | 32 GB HBM2 | iMac Pro, Mac Pro (2019) | – |
| Radeon Pro Vega II Duo | 2× Vega 20 | 2× 32 GB HBM2 | iMac Pro, Mac Pro (2019) | on-card link |
| Radeon Pro W5700X | Navi 10 (RDNA 1) | 16 GB GDDR6 | Mac Pro (2019) | – |
| Radeon Pro W6800X | Navi 21 (RDNA 2) | 32 GB GDDR6 | Mac Pro (2019) | – |
| Radeon Pro W6800X Duo | 2× Navi 21 | 2× 32 GB GDDR6 | Mac Pro (2019) | on-card bridge |
| Radeon Pro W6900X | Navi 21 (RDNA 2) | 32 GB GDDR6 | Mac Pro (2019) | – |

### Multi-card configurations

A cross-card **Infinity Fabric link** — available as a **link jumper** or a
**link bridge** — can join two MPX cards into one xGMI hive, giving direct
GPU-to-GPU peer paths that bypass the host:

| Configuration | Cross-card link | GPU partitions | Infinity Fabric |
|---|---|---|---|
| 2× Radeon Pro W6800X Duo | link jumper | 4× Navi 21 | on-card bridges **plus** cross-card jumper; TODO: confirm hive formation/bandwidth vs bridge |
| 2× Radeon Pro W6800X Duo | link bridge | 4× Navi 21 | on-card bridges **plus** cross-card bridge → single 4-node xGMI hive (evidence below) |
| 2× Radeon Pro W6900X | link jumper | 2× Navi 21 | cross-card jumper; TODO: confirm hive formation/bandwidth vs bridge |
| 2× Radeon Pro W6900X | link bridge | 2× Navi 21 | cross-card bridge |
| 2× Radeon Pro Vega II | link jumper | 2× Vega 20 | cross-card jumper; TODO: confirm hive formation/bandwidth vs bridge |
| 2× Radeon Pro Vega II | link bridge | 2× Vega 20 | cross-card bridge |
| 2× Radeon Pro Vega II Duo | link jumper | 4× Vega 20 | on-card bridges **plus** cross-card jumper ⚠️¹ |
| 2× Radeon Pro Vega II Duo | link bridge | 4× Vega 20 | on-card bridges **plus** cross-card bridge ⚠️¹ |

> Both MPX cards and the chassis provide for two cross-card interconnect
> options — a **link jumper** and a **link bridge**. The evidence below was
> captured on a linked 2× W6800X Duo system (jumper vs bridge not recorded at
> capture time — TODO: re-check); whether (and how) the jumper forms an xGMI
> hive is TODO, as are the two options' link widths and part numbers.
>
> Evidence (Mac Pro 2019, 2× W6800X Duo cross-card linked, macOS 26.6.2):
> IORegistry reports
> `InfinityFabricLinks = Yes`, `XGMI_Enabled = Yes`, one shared `XGMI_HiveID`
> with `XGMI_HiveSize = 4` and `XGMI_NodeIndex` 0–3 (two nodes per card).
> Without a cross-card link, cross-card traffic falls back to the PCIe host
> path.
> TODO: jumper/bridge part numbers, supported pairings per option, link
> widths, and measured bandwidth
> (see [docs/hardware/infinity-fabric.md](docs/hardware/infinity-fabric.md)).
>
> ⚠️ ¹ The 2× Vega II Duo cross-card configuration (either link jumper or
> link bridge) **may not be a configuration Apple supports**; it is documented
> here as a potentially achievable topology. TODO: confirm Apple's official
> supported configuration list and record whether this pairing is officially
> supported, merely undocumented, or explicitly excluded.

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
swift run --package-path examples/swift device-basics

# (if-bench, mtl-bench, and iokit-dump land in Phases 2-3; their READMEs
# describe the planned interfaces)

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
