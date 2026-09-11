import Foundation
import IOKit
import Metal
import ToolSupport

// if-bench: bandwidth and latency across the memory paths that matter on
// MPX hosts — local VRAM, IOSurface staging between two MTLDevices (the
// supported cross-device sharing route), and host<->GPU over PCIe — with a
// concurrent-load mode as repro for co-scheduling issues. JSON output is
// paste-ready for docs/benchmarks/ reports. See tools/if-bench/README.md.

let arguments = CommandLine.arguments

func printUsage() {
    print(
        """
        usage: if-bench [options]

        Measures copy bandwidth (pipelined blits/compute dispatches) and
        latency (dependent copy chains) for:

          local      device -> own VRAM (baseline)
          peer       device A <-> device B via one IOSurface staging region
                     (two hops: A->staging, staging->B)
          host       CPU <-> device through a shared (host-backed) buffer
          concurrent local load on both devices at once vs. alone

        Options:
          --device-a N      index into MTLCopyAllDevices() (default 0)
          --device-b N      second device index (default 1; default pair is
                            checked for cross-device coherence first)
          --min-size BYTES  sweep start (default 4096)
          --max-size BYTES  sweep end (default 67108864 = 64 MiB)
          --path blit|kernel|both    copy implementation under test (default both)
          --mode bw|latency|peer|host|concurrent|all  (default all)
          --list-devices    print the device table and exit
          --json            machine-readable output
          -h, --help
        """
    )
}

var opts = (
    deviceA: 0, deviceB: 1,
    minSize: 4096, maxSize: 67_108_864,
    paths: Set(["blit", "kernel"]),
    modes: Set(["bw", "latency", "peer", "host", "concurrent"]),
    json: false, list: false
)

var i = 1
while i < arguments.count {
    func next() -> Int? {
        i += 1
        guard i < arguments.count else { return nil }
        return Int(arguments[i])
    }
    switch arguments[i] {
    case "-h", "--help": printUsage(); exit(0)
    case "--json": opts.json = true
    case "--list-devices": opts.list = true
    case "--device-a": if let v = next() { opts.deviceA = v }
    case "--device-b": if let v = next() { opts.deviceB = v }
    case "--min-size": if let v = next() { opts.minSize = v }
    case "--max-size": if let v = next() { opts.maxSize = v }
    case "--path":
        i += 1
        guard i < arguments.count else { break }
        if arguments[i] == "both" { opts.paths = ["blit", "kernel"] }
        else { opts.paths = [arguments[i]] }
    case "--mode":
        i += 1
        guard i < arguments.count else { break }
        if arguments[i] == "all" { opts.modes = ["bw", "latency", "peer", "host", "concurrent"] }
        else { opts.modes = [arguments[i]] }
    default:
        FileHandle.standardError.write(Data("if-bench: unknown argument \(arguments[i])\n".utf8))
        printUsage()
        exit(2)
    }
    i += 1
}

// MARK: - Devices and PCI correlation

let metalDevices = MTLCopyAllDevices()

func emitReport(devices: [[String: Any]], results: [[String: Any]], notes: [String]) -> Never {
    var report: [String: Any] = [
        "tool": "if-bench",
        "version": "1",
        "machine": MachineInfo.report(),
        "devices": devices,
        "results": results,
        "notes": notes,
    ]
    if opts.json {
        report["options"] = [
            "deviceA": opts.deviceA, "deviceB": opts.deviceB,
            "minSize": opts.minSize, "maxSize": opts.maxSize,
            "paths": opts.paths.sorted(), "modes": opts.modes.sorted(),
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }
    print("== if-bench ==")
    for note in notes { print("note: \(note)") }
    for device in devices {
        print("- device[\(device["index"] as? Int ?? -1)] "
            + "\(device["name"] as? String ?? "?")"
            + "  slot=\(device["slot"] as? String ?? "?")"
            + "  node=\(device["xgmiNodeIndex"] as? String ?? "?")"
            + " hive=\(device["xgmiHiveSize"] as? String ?? "?")")
    }
    for r in results {
        let kind = r["kind"] as? String ?? "?"
        let dir = r["direction"] as? String ?? "?"
        let size = r["sizeBytes"] as? Int ?? 0
        if kind == "bandwidth", let gb = r["gbytesPerSecond"] as? Double {
            print(String(format: "bandwidth  %-28@ %8d KiB  %8.2f GB/s (%@)",
                         dir as NSString, size / 1024, gb,
                         (r["copyPath"] as? String ?? "blit") as NSString))
        } else if kind == "latency", let us = r["usPerHop"] as? Double {
            print(String(format: "latency    %-28@ %8d KiB  %8.2f us/hop",
                         dir as NSString, size / 1024, us))
        } else if let note = r["note"] as? String {
            print("skipped    \(dir): \(note)")
        }
    }
    exit(0)
}

func deviceSummary(_ device: MTLDevice, index: Int) -> [String: Any] {
    var info: [String: Any] = [
        "index": index,
        "name": device.name,
        "registryIDHex": String(format: "0x%016llx", MetalInfo.registryID(of: device)),
        "recommendedMaxWorkingSetSize": Int(device.recommendedMaxWorkingSetSize),
    ]
    if device.isHeadless { info["headless"] = true }
    return info
}

if metalDevices.isEmpty {
    emitReport(devices: [], results: [],
               notes: ["no Metal devices visible in this session; nothing to measure"])
}
guard opts.deviceA != opts.deviceB else {
    emitReport(devices: metalDevices.enumerated().map { deviceSummary($0.element, index: $0.offset) },
               results: [], notes: ["--device-a equals --device-b: peer modes need two devices"])
}

var notes: [String] = []

// Attach PCI slot / xGMI info to every device (same correlation method as
// gpu-probe: MTLDevice.registryID == IOKit registry-entry id).
let pciDevices = IORegistryHelper.allPCIDevices()
let subtrees = pciDevices.map { PCISubtree(device: $0) }
for device in pciDevices { IOObjectRelease(device) }
var indexByID: [UInt64: (subtree: PCISubtree, entry: io_registry_entry_t)] = [:]
for subtree in subtrees {
    for (id, entry) in subtree.entriesByID where indexByID[id] == nil {
        indexByID[id] = (subtree, entry)
    }
}
let hiveKeys: Set<String> = [
    "InfinityFabricLinks", "XGMI_Enabled", "XGMI_HiveSize", "XGMI_NodeIndex",
]

func enrich(_ device: MTLDevice, _ info: inout [String: Any]) {
    let fullID = MetalInfo.registryID(of: device)
    guard let hit = indexByID[fullID] ?? indexByID[UInt64(UInt32(truncatingIfNeeded: fullID))],
          let pci = IORegistryHelper.ancestor(of: hit.entry, conformingTo: "IOPCIDevice")
    else { return }
    defer { IOObjectRelease(pci) }
    var nameBuf = [CChar](repeating: 0, count: 256)
    IORegistryEntryGetName(pci, &nameBuf)
    info["pciService"] = String(cString: nameBuf)
    info["pciRegistryEntryID"] = IORegistryHelper.entryID(of: pci)
        .map { String(format: "0x%016llx", $0) }
    if let slot = IORegistryHelper.property(pci, "AAPL,slot-name") as? String {
        info["slot"] = slot
    }
    let subtree = PCISubtree.serviceSubtree(of: pci)
    defer { for e in subtree { IOObjectRelease(e) } }
    for found in IORegistryHelper.scanAll(entries: subtree, forKeys: hiveKeys) {
        switch found.key {
        case "XGMI_NodeIndex": info["xgmiNodeIndex"] = "\(found.value)"
        case "XGMI_HiveSize": info["xgmiHiveSize"] = "\(found.value)"
        case "XGMI_Enabled": info["xgmiEnabled"] = "\(found.value)"
        case "InfinityFabricLinks": info["infinityFabricLinks"] = "\(found.value)"
        default: break
        }
    }
}

var deviceInfos: [[String: Any]] = []
for (index, device) in metalDevices.enumerated() {
    var info = deviceSummary(device, index: index)
    enrich(device, &info)
    deviceInfos.append(info)
}

if opts.list {
    emitReport(devices: deviceInfos, results: [], notes: notes)
}

guard opts.deviceA < metalDevices.count, opts.deviceB < metalDevices.count,
      opts.deviceA >= 0, opts.deviceB >= 0
else {
    emitReport(devices: deviceInfos, results: [],
               notes: ["requested device indices out of range (\(metalDevices.count) devices)"])
}

let ctxA = DeviceCtx(index: opts.deviceA, device: metalDevices[opts.deviceA])
let ctxB = DeviceCtx(index: opts.deviceB, device: metalDevices[opts.deviceB])
if ctxA.copyPipeline == nil || ctxB.copyPipeline == nil {
    notes.append("kernel copy path unavailable (compute pipeline compile failed); "
        + "kernel rows skipped")
}
let workingSet = min(metalDevices[opts.deviceA].recommendedMaxWorkingSetSize,
                     metalDevices[opts.deviceB].recommendedMaxWorkingSetSize)
let maxSize = min(opts.maxSize, Int(workingSet / 2))
if maxSize < opts.maxSize {
    notes.append("sweep capped at \(maxSize) bytes (half of recommendedMaxWorkingSetSize)")
}

var sizes: [Int] = []
var size = max(opts.minSize, 64)
while size <= maxSize {
    sizes.append(size)
    size *= 2
}

var results: [[String: Any]] = []

func progress(_ line: String) {
    FileHandle.standardError.write(Data("if-bench: \(line)\n".utf8))
}

func bandwidthRow(_ direction: String, _ path: String, bytes: Int, seconds: Double) {
    guard seconds > 0 else { return }
    let gbps = Double(bytes) / seconds / 1e9
    results.append([
        "kind": "bandwidth", "direction": direction, "copyPath": path,
        "sizeBytes": bytes, "seconds": seconds,
        "gbytesPerSecond": (gbps * 100).rounded() / 100,
    ])
}

func latencyRow(_ direction: String, bytes: Int, secondsPerHop: Double) {
    results.append([
        "kind": "latency", "direction": direction, "sizeBytes": bytes,
        "usPerHop": (secondsPerHop * 1e6 * 100).rounded() / 100,
    ])
}

let labelA = "dev\(opts.deviceA)"
let labelB = "dev\(opts.deviceB)"

// MARK: - Local (baseline)

if opts.modes.contains("bw") {
    for ctx in [ctxA, ctxB] {
        let label = ctx.index == opts.deviceA ? labelA : labelB
        for s in sizes {
            progress("bandwidth \(label) local \(s) bytes")
            if opts.paths.contains("blit"),
               let t = localBandwidth(ctx, size: s, useKernel: false) {
                bandwidthRow("\(label) local", "blit", bytes: s, seconds: t)
            }
            if opts.paths.contains("kernel"), ctx.copyPipeline != nil,
               let t = localBandwidth(ctx, size: s, useKernel: true) {
                bandwidthRow("\(label) local", "kernel", bytes: s, seconds: t)
            }
        }
    }
}

if opts.modes.contains("latency") {
    for ctx in [ctxA, ctxB] {
        let label = ctx.index == opts.deviceA ? labelA : labelB
        for s in sizes where s <= 4_194_304 {  // ping-pong sweeps stay <= 4 MiB
            progress("latency \(label) local \(s) bytes")
            if let t = localLatency(ctx, size: s, roundTrips: 200) {
                latencyRow("\(label) local", bytes: s, secondsPerHop: t)
            }
        }
    }
}

// MARK: - Peer (cross-device via IOSurface staging)

if opts.modes.contains("peer") {
    progress("peer coherence check")
    var coherent = false
    if let gate = Staging(size: 65_536) {
        coherent = peerCoherenceCheck(ctxA, ctxB, staging: gate)
    }
    if !coherent {
        notes.append("cross-device coherence check FAILED: peer rows omitted; "
            + "on this driver/OS the IOSurface staging route is not usable "
            + "between the selected devices")
    } else {
        notes.append("peer = two-hop path via one IOSurface staging region "
            + "(A->staging + staging->B); the API does not reveal whether "
            + "staging pages are host-resident or IF-migrated — interpret "
            + "peer numbers as 'best cross-device path available to Metal', "
            + "not as raw link bandwidth")
        for s in sizes {
            progress("peer sweep \(s) bytes")
            guard let staging = Staging(size: s) else { continue }
            let hopBytes = min(s, staging.stride)  // stride rounds s up to bpr rows
            // Isolated hops, both directions, both devices.
            for (ctx, label) in [(ctxA, labelA), (ctxB, labelB)] {
                if let t = stagingHopBandwidth(ctx, staging: staging, write: true) {
                    bandwidthRow("\(label)->staging", "blit", bytes: hopBytes, seconds: t)
                }
                if let t = stagingHopBandwidth(ctx, staging: staging, write: false) {
                    bandwidthRow("staging->\(label)", "blit", bytes: hopBytes, seconds: t)
                }
            }
            // End-to-end A->B and B->A (two hops each).
            if let t = peerBandwidth(ctxA, ctxB, staging: staging) {
                bandwidthRow("\(labelA)->\(labelB) (2 hops)", "blit", bytes: 2 * hopBytes, seconds: t)
            }
            if let t = peerBandwidth(ctxB, ctxA, staging: staging) {
                bandwidthRow("\(labelB)->\(labelA) (2 hops)", "blit", bytes: 2 * hopBytes, seconds: t)
            }
            // Dependent round-trip latency (4 hops/repetition), small sizes only.
            if s <= 1_048_576,
               let t = peerRoundTripLatency(ctxA, ctxB, staging: staging, roundTrips: 100) {
                latencyRow("\(labelA)<->\(labelB)", bytes: s, secondsPerHop: t)
            }
        }
    }
}

// MARK: - Host <-> GPU (PCIe path approximations)

if opts.modes.contains("host") {
    notes.append("host directions use storageModeShared buffers: on Intel "
        + "these are host RAM, so 'totalMinusCPU' attributes the non-CPU "
        + "time to GPU access + flush over PCIe (approximation)")
    for ctx in [ctxA, ctxB] {
        let label = ctx.index == opts.deviceA ? labelA : labelB
        for s in sizes where s <= 268_435_456 {  // host sweep capped at 256 MiB
            progress("host sweep \(label) \(s) bytes")
            if let (total, cpu) = hostUpBandwidth(ctx, size: s) {
                let gpu = max(total - cpu, 0)
                bandwidthRow("host->\(label) (total)", "memset+kernel", bytes: s, seconds: total)
                bandwidthRow("host->\(label) (gpu part)", "memset+kernel", bytes: s, seconds: gpu)
            }
            if let (total, cpu) = hostDownBandwidth(ctx, size: s) {
                let gpu = max(total - cpu, 0)
                bandwidthRow("\(label)->host (total)", "kernel+read", bytes: s, seconds: total)
                bandwidthRow("\(label)->host (gpu part)", "kernel+read", bytes: s, seconds: gpu)
            }
        }
    }
}

// MARK: - Concurrent load (co-scheduling repro)

if opts.modes.contains("concurrent") {
    let s = min(33_554_432, maxSize)  // 32 MiB working point
    progress("concurrent-load repro at \(s) bytes")
    let path: String = ctxA.copyPipeline != nil && opts.paths.contains("kernel") ? "kernel" : "blit"
    if let soloA = localBandwidth(ctxA, size: s, useKernel: path == "kernel").map({ Double(s) * Double(iterations(for: s)) / $0 }),
       let soloB = localBandwidth(ctxB, size: s, useKernel: path == "kernel").map({ Double(s) * Double(iterations(for: s)) / $0 }) {
        results.append([
            "kind": "bandwidth", "direction": "\(labelA) solo", "copyPath": path,
            "sizeBytes": s, "gbytesPerSecond": ((soloA / 1e9) * 100).rounded() / 100,
        ])
        results.append([
            "kind": "bandwidth", "direction": "\(labelB) solo", "copyPath": path,
            "sizeBytes": s, "gbytesPerSecond": ((soloB / 1e9) * 100).rounded() / 100,
        ])
        // Run both at once; wall-clock throughput per device.
        let n = iterations(for: s)
        var wallSeconds: Double = 0
        let group = DispatchGroup()
        let wall = measuredSeconds {
            group.enter()
            group.enter()
            DispatchQueue.global().async {
                _ = localBandwidth(ctxA, size: s, useKernel: path == "kernel")
                group.leave()
            }
            DispatchQueue.global().async {
                _ = localBandwidth(ctxB, size: s, useKernel: path == "kernel")
                group.leave()
            }
            group.wait()
        }
        wallSeconds = wall
        // Each device moved n*size bytes within `wallSeconds` measured
        // wall-clock (includes the other device's ramp; conservative).
        _ = n
        bandwidthRow("\(labelA) concurrent", path, bytes: s * n, seconds: wallSeconds)
        bandwidthRow("\(labelB) concurrent", path, bytes: s * n, seconds: wallSeconds)
    }
}

emitReport(devices: deviceInfos, results: results, notes: notes)
