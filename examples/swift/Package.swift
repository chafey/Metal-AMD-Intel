// swift-tools-version: 5.9
import PackageDescription

// Swift examples for Metal-AMD-Intel. Each example is an executable target
// under Sources/. Tools live in their own package at tools/Package.swift.
let package = Package(
    name: "metal-amd-intel-examples",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "device-basics",
            path: "Sources/device-basics"
        ),
        // Phase 4 will add: multi-gpu, if-peer-access
    ]
)
