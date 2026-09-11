import Foundation
import IOKit
import Metal
import ToolSupport

// gpu-probe: enumerate every MTLDevice with its backing IOKit registry
// properties and the machine environment, paste-ready for benchmark
// reports (docs/benchmarks/TEMPLATE.md). See tools/gpu-probe/README.md.

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        usage: gpu-probe [--json]

        Enumerates MTLDevices (Metal) plus their backing IOPCIDevice registry
        properties, xGMI/Infinity-Fabric hive properties, and the machine /
        OS / AMD driver environment.

          --json   emit machine-readable JSON instead of the human summary
          -h, --help
        """
    )
    exit(0)
}

let asJSON = arguments.contains("--json")

// Registry keys carrying the xGMI hive info. Confirmed live on a 2×
// W6800X Duo system (2026-09-11): all four live on the GFX0/GFX1
// IOPCIDevice nodes; see docs/hardware/mpx-cards.md "Open questions".
let hiveKeys: Set<String> = [
    "InfinityFabricLinks", "XGMI_Enabled", "XGMI_HiveSize", "XGMI_NodeIndex",
]
let pciIDKeys = [
    "vendor-id", "device-id", "revision-id",
    "subsystem-vendor-id", "subsystem-id", "class-code",
]

func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let data as Data:
        return "(\(data.count) bytes) "
            + data.prefix(16).map { String(format: "%02x", $0) }.joined()
    case let array as [Any]:
        return array.map(jsonSafe)
    case let dict as [String: Any]:
        return dict.mapValues(jsonSafe)
    default:
        return String(describing: value)
    }
}

// MARK: - IOKit side: PCI subtrees and a global registry-id index

let pciDevices = IORegistryHelper.allPCIDevices()
let subtrees = pciDevices.map { PCISubtree(device: $0) }
for device in pciDevices { IOObjectRelease(device) }

var indexByID: [UInt64: (subtree: PCISubtree, entry: io_registry_entry_t)] = [:]
for subtree in subtrees {
    for (id, entry) in subtree.entriesByID where indexByID[id] == nil {
        indexByID[id] = (subtree, entry)
    }
}

// Each PCI device's *own* subtree (not just the first subtree that happens
// to contain it), so scans after correlation stay within the GPU's function.
var ownedByRoot: [UInt64: PCISubtree] = [:]
for subtree in subtrees {
    if let id = IORegistryHelper.entryID(of: subtree.device) {
        ownedByRoot[id] = subtree
    }
}

/// Decode IOPCIExpressLinkStatus (PCIe r3.0 §7.5.3.19): bits 0-3 are the
/// negotiated speed, bits 4-9 the negotiated lane width.
func decodeLinkStatus(_ raw: UInt64) -> String? {
    let speedCode = UInt8(raw & 0xF)
    let width = (raw >> 4) & 0x3F
    guard let gt = [1: "2.5", 2: "5", 3: "8", 4: "16", 5: "32"][Int(speedCode)],
          width > 0
    else { return nil }
    return "\(gt) GT/s x\(width)"
}

// MARK: - Metal side: probe each device and correlate

let metalDevices = MTLCopyAllDevices()
var deviceReports: [[String: Any]] = []

for device in metalDevices {
    var report = MetalInfo.report(for: device)
    let fullID = MetalInfo.registryID(of: device)
    // Prefer the full 64-bit registry-entry id; fall back to its low 32 bits
    // (older SDKs truncated registryID to uint32).
    let hit = indexByID[fullID] ?? indexByID[UInt64(UInt32(truncatingIfNeeded: fullID))]
    if let hit {
        // The matched node is usually the accelerator *service*; walk up to
        // the IOPCIDevice function it hangs off so PCI ids and subtree
        // scans describe the GPU function, not the root port above it.
        let ancestorOpt = IORegistryHelper.ancestor(of: hit.entry, conformingTo: "IOPCIDevice")
        defer { if let a = ancestorOpt { IOObjectRelease(a) } }
        let pci = ancestorOpt ?? hit.subtree.device
        let ownSubtree = IORegistryHelper.entryID(of: pci).flatMap { ownedByRoot[$0] }
            ?? hit.subtree

        var nameBuf = [CChar](repeating: 0, count: 256)
        IORegistryEntryGetName(pci, &nameBuf)
        let pciServiceName = String(cString: nameBuf)
        let pciRootID = IORegistryHelper.entryID(of: pci)

        report["correlation"] = [
            "method": "registryEntryID",
            "node": IORegistryHelper.className(of: hit.entry) ?? "unknown",
            "pciService": pciServiceName,
            "pciRegistryEntryID": pciRootID.map { String(format: "0x%016llx", $0) } ?? "?",
        ]
        var pciInfo: [String: Any] = [:]
        for key in pciIDKeys {
            if let value = IORegistryHelper.numericProperty(pci, key) {
                pciInfo[key] = String(format: "0x%08x", UInt32(truncatingIfNeeded: value))
            }
        }
        if let slot = IORegistryHelper.property(pci, "AAPL,slot-name") as? String {
            pciInfo["AAPL,slot-name"] = slot
        }
        if let linkRaw = IORegistryHelper.numericProperty(pci, "IOPCIExpressLinkStatus") {
            pciInfo["IOPCIExpressLinkStatus"] = String(format: "0x%04x", UInt16(truncatingIfNeeded: linkRaw))
            if let decoded = decodeLinkStatus(linkRaw) {
                pciInfo["negotiatedLink"] = decoded
            }
        }
        report["pci"] = pciInfo

        let hive = IORegistryHelper.scanAll(entries: ownSubtree.allEntries, forKeys: hiveKeys)
        if !hive.isEmpty {
            report["xgmi"] = hive.map {
                ["node": $0.node, "key": $0.key, "value": jsonSafe($0.value)]
            }
        }

        // Anything else link-related (negotiated widths live in
        // IOPCIExpressLinkStatus, decoded above; DP link properties are
        // display-side and kept for triage only).
        let linkProps = IORegistryHelper.properties(matching: "link", in: ownSubtree.allEntries)
        if !linkProps.isEmpty {
            report["linkProperties"] = linkProps.map {
                ["node": $0.node, "key": $0.key, "value": jsonSafe($0.value)]
            }
        }
    } else {
        report["correlation"] = [
            "method": "none",
            "note": "no registry entry id matched MTLDevice.registryID (full or low 32 bits)",
        ]
    }
    deviceReports.append(report)
}

// Duo-partition correlation: Metal devices whose backing registry-entry id
// is the same IOPCIDevice function sit on one physical module (a Duo card
// exposes one PCI function per... partition or one shared — report as seen).
var byPCI: [String: [String]] = [:]
for report in deviceReports {
    guard
        let correlation = report["correlation"] as? [String: Any],
        let rootID = correlation["pciRegistryEntryID"] as? String,
        let pciService = correlation["pciService"] as? String
    else { continue }
    let name = "\(report["name"] as? String ?? "?")/\(report["registryIDHex"] as? String ?? "?")"
    byPCI["\(pciService)@\(rootID)", default: []].append(name)
}
let sameModule = byPCI.filter { $0.value.count > 1 }

// MARK: - Output

let environment = MachineInfo.report()

if asJSON {
    var report: [String: Any] = [
        "tool": "gpu-probe",
        "version": "2",
        "machine": environment,
        "devices": deviceReports,
    ]
    if !sameModule.isEmpty {
        report["samePhysicalModule"] = sameModule
    }
    let data = try! JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

print("== gpu-probe ==")
print("IOKit: \(subtrees.count) PCI device subtrees, \(indexByID.count) registry ids indexed")
print("Model:  \(environment["model"] as? String ?? "?")")
print("CPU:    \(environment["cpu"] as? String ?? "?") (\(environment["cpuCores"] as? Int ?? 0) cores)")
let ram = (environment["memoryBytes"] as? UInt64).map { Double($0) / 1_073_741_824 } ?? 0
print("RAM:    \(String(format: "%.0f", ram)) GB")
print("macOS:  \(environment["macOS"] as? String ?? "?") (\(environment["osBuild"] as? String ?? "?")) \(environment["arch"] as? String ?? "")")
if let drivers = environment["amdDrivers"] as? [String: String], !drivers.isEmpty {
    print("AMD drivers:")
    for (kext, version) in drivers.sorted(by: { $0.key < $1.key }) {
        print("  \(kext): \(version)")
    }
}

if metalDevices.isEmpty {
    print("\nNo Metal devices visible (headless session or no GPU access).")
}

for report in deviceReports {
    print("\n- \(report["name"] as? String ?? "?") [\(report["registryIDHex"] as? String ?? "?")]")
    print("    workingSet: \(report["recommendedMaxWorkingSetSize"] as? Int ?? 0) bytes")
    let families = (report["gpuFamilies"] as? [String] ?? []).joined(separator: ", ")
    print("    families: \(families.isEmpty ? "none" : families)"
        + "  maxFeatureSet: \(report["maxFeatureSet"] as? String ?? "?")")
    if let correlation = report["correlation"] as? [String: Any] {
        if (correlation["method"] as? String) == "registryEntryID" {
            print("    pci: \(correlation["pciService"] as? String ?? "?")"
                + " (node: \(correlation["node"] as? String ?? "?"))")
            if let pci = report["pci"] as? [String: Any] {
                let fields = pciIDKeys.compactMap { key -> String? in
                    pci[key].map { "\(key)=\($0)" }
                }
                var line = "         " + fields.joined(separator: " ")
                if let slot = pci["AAPL,slot-name"] as? String { line += "  slot=\(slot)" }
                print(line)
                if let link = pci["negotiatedLink"] as? String,
                   let status = pci["IOPCIExpressLinkStatus"] as? String {
                    print("         PCIe link: \(link)  (IOPCIExpressLinkStatus=\(status))")
                }
            }
        } else {
            print("    pci: NOT CORRELATED (\(correlation["note"] as? String ?? ""))")
        }
    }
    if let hive = report["xgmi"] as? [[String: Any]] {
        for entry in hive {
            print("    xgmi: \(entry["key"] as? String ?? "?")=\(entry["value"] as? String ?? "?")"
                + " (on \(entry["node"] as? String ?? "?"))")
        }
    }
    if let linkProps = report["linkProperties"] as? [[String: Any]], !linkProps.isEmpty {
        // Only the PCIe link-status lines in human output; full list in
        // --json (includes display-link properties).
        let status = linkProps.filter {
            ($0["key"] as? String) == "IOPCIExpressLinkStatus"
        }
        for prop in status {
            let raw = UInt64(prop["value"] as? String ?? "") ?? 0
            let decoded = decodeLinkStatus(raw).map { " → \($0)" } ?? ""
            print("    link: \(prop["node"] as? String ?? "?").IOPCIExpressLinkStatus"
                + " = \(prop["value"] as? String ?? "?")\(decoded)")
        }
        let extra = linkProps.count - status.count
        if extra > 0 { print("    (+\(extra) other link properties, see --json)") }
    }
}

if !sameModule.isEmpty {
    print("\nSame-module partitions (Metal devices on one IOPCIDevice function):")
    for (pci, names) in sameModule.sorted(by: { $0.key < $1.key }) {
        print("  \(pci):")
        for name in names { print("    - \(name)") }
    }
}
