import Foundation
import Metal

// gpu-probe: placeholder scaffold. Phase 2 implements the full report; see
// tools/gpu-probe/README.md for the planned output schema.

let asJSON = CommandLine.arguments.contains("--json")

// MTLDevice.registryID has been declared as both uint32_t and uint64_t in
// different SDKs; normalize to UInt64 so this compiles and runs against
// either declaration (a bare `as! UInt32` traps on macOS 26 SDKs).
struct DeviceInfo {
    let name: String
    let registryID: UInt64
}

let devices = MTLCopyAllDevices().map { device in
    DeviceInfo(name: device.name, registryID: UInt64(device.registryID))
}

if asJSON {
    let report: [String: Any] = [
        "tool": "gpu-probe",
        "version": "scaffold",
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "devices": devices.map {
            ["name": $0.name, "registryID": $0.registryID, "scaffold": true] as [String: Any]
        },
    ]
    let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    print("gpu-probe: scaffold only (Phase 2 will implement full probing)")
    print("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for device in devices {
        print("- \(device.name) (registryID: \(device.registryID))")
    }
}
