// swift-tools-version: 5.9
import PackageDescription

// Swift tools for Metal-AMD-Intel. Each tool is an executable target under
// Sources/. Examples live in their own package at examples/swift/.
let package = Package(
    name: "metal-amd-intel-tools",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "gpu-probe",
            path: "Sources/gpu-probe"
        ),
        // Phase 2/3 will add: if-bench
    ]
)
