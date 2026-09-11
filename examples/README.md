# Examples

Worked examples demonstrating MPX / Duo / Infinity Fabric usage. Each example
is self-contained, has its own README stating what it demonstrates, and must
compile in CI. Swift examples build through the SwiftPM package at
`examples/swift/Package.swift` (each is its own executable target); C/C++
examples build via CMake from the root `Makefile`.

| Example | Language | Demonstrates |
|---|---|---|
| [swift/device-basics](swift/device-basics/) | Swift | Device selection & capability probing |
| [swift/multi-gpu](swift/multi-gpu/) | Swift | Command buffers across two GPUs |
| [swift/if-peer-access](swift/if-peer-access/) | Swift | Sharing buffers across the Infinity Fabric Link jumper |
| [c-cpp/metal-c-basic](c-cpp/metal-c-basic/) | Metal-c | Minimal objc-free compute pipeline |
| [c-cpp/mpsc-ring](c-cpp/mpsc-ring/) | C++ | Steady-state timing via producer/consumer GPU workload |
