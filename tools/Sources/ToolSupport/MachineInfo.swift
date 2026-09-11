import Foundation

// Machine / OS / driver environment block, matching the "paste-ready
// environment block" promised in tools/gpu-probe/README.md.

public enum MachineInfo {
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func report() -> [String: Any] {
        var info: [String: Any] = [:]
        info["model"] = sysctlString("hw.model") ?? "unknown"
        info["cpu"] = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        info["cpuCores"] = ProcessInfo.processInfo.processorCount
        info["memoryBytes"] = ProcessInfo.processInfo.physicalMemory

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        info["macOS"] = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        info["osBuild"] = sysctlString("kern.osversion") ?? "unknown"
        info["arch"] = sysctlString("hw.machine") ?? "unknown"

        let drivers = amdDriverVersions()
        if !drivers.isEmpty { info["amdDrivers"] = drivers }
        return info
    }

    /// Bundle versions of the AMD GPU kexts / accelerator families present on
    /// the system, from both /System/Library/Extensions and /Library/Extensions.
    public static func amdDriverVersions() -> [String: String] {
        let prefixes = ["AMDRadeon", "AMDFramebuffer", "IOAcceleratorFamily"]
        let dirs = [
            "/System/Library/Extensions",
            "/Library/Extensions",
        ]
        var versions: [String: String] = [:]
        let fm = FileManager.default
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() where prefixes.contains(where: { entry.hasPrefix($0) }) {
                let plist = dir + "/" + entry + "/Contents/Info.plist"
                guard
                    let dict = NSDictionary(contentsOfFile: plist),
                    let version = dict["CFBundleVersion"] as? String
                else { continue }
                versions[entry] = version
            }
        }
        return versions
    }
}
