import Foundation
import Metal

// device-basics: placeholder scaffold. Phase 4 implements device selection
// and capability probing; see examples/swift/device-basics/README.md.

print("device-basics: scaffold only (Phase 4 will implement selection & probing)")
for device in MTLCopyAllDevices() {
    print("- \(device.name): maxWorkingSet=\(device.recommendedMaxWorkingSetSize)")
}
