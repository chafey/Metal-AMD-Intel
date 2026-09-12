// swift-tools-version: 5.9
import PackageDescription

// Swift tools for Metal-AMD-Intel. Each tool is an executable target under
// Sources/; shared IOKit/Metal/environment helpers live in ToolSupport.
// Examples live in their own package at examples/swift/.
let package = Package(
    name: "metal-amd-intel-tools",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "ToolSupport",
            path: "Sources/ToolSupport"
        ),
        .executableTarget(
            name: "gpu-probe",
            dependencies: ["ToolSupport"],
            path: "Sources/gpu-probe"
        ),
        .executableTarget(
            name: "if-bench",
            dependencies: ["ToolSupport"],
            path: "Sources/if-bench"
        ),
        .executableTarget(
            name: "tp-sim",
            dependencies: ["ToolSupport"],
            path: "Sources/tp-sim"
        ),
        .executableTarget(
            name: "pull-contention",
            path: "Sources/pull-contention"
        ),
    ]
)
