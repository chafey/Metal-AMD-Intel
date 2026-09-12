import Foundation
import Metal
import ObjectiveC

// Per-MTLDevice Metal-side facts: identity, memory limits, and capability
// probes. Correlation with IOKit happens in main.swift via `registryID`.

public enum MetalInfo {
    /// `MTLDevice.registryID` has been declared as both `uint32_t` and
    /// `uint64_t` across SDKs; normalize to UInt64 (a bare narrowing cast
    /// traps on macOS 26 SDKs where ids exceed UInt32.max).
    public static func registryID(of device: MTLDevice) -> UInt64 {
        UInt64(device.registryID)
    }

    public static func report(for device: MTLDevice) -> [String: Any] {
        var info: [String: Any] = [:]
        info["name"] = device.name
        info["registryID"] = registryID(of: device)
        info["registryIDHex"] = String(format: "0x%016llx", registryID(of: device))
        // NB: `MTLDevice.location`/`entryPoint` (encoded PCIe numbers in the
        // macOS 15 SDKs) were removed/remodeled by the macOS 26 SDK; PCI
        // position comes from IOKit instead (AAPL,slot-name etc.).
        info["isHeadless"] = device.isHeadless
        info["peerGroupIDHex"] = String(format: "0x%016llx", device.peerGroupID)
        info["recommendedMaxWorkingSetSize"] = Int(device.recommendedMaxWorkingSetSize)
        info["maxThreadsPerThreadgroup"] = [
            "width": device.maxThreadsPerThreadgroup.width,
            "height": device.maxThreadsPerThreadgroup.height,
            "depth": device.maxThreadsPerThreadgroup.depth,
        ]

        // MTLGPUFamily/MTLFeatureSet enum cases come and go with SDKs (some
        // were removed by the macOS 26 SDK), and the Swift overlays' raw
        // initializers changed shape. Probe the underlying ObjC methods
        // directly with the wire values from MTLDevice.h:
        //   MTLGPUFamily: mac1 = 2001, mac2 = 2002, common1..3 = 3001..3,
        //     metal3 = 5001, metal4 = 5002 (macOS 26)
        let families: [(String, UInt)] = [
            ("mac1", 2001),
            ("mac2", 2002),
            ("common1", 3001),
            ("common2", 3002),
            ("common3", 3003),
            ("metal3", 5001),
            ("metal4", 5002),
        ]
        info["gpuFamilies"] = families.filter {
            supports(device, "supportsFamily:", $0.1)
        }.map(\.0)

        // MTLFeatureSet wire values (MTLDevice.h): GPUFamily1_v1 = 10000,
        // v2 = 10001, v3 = 10003, v4 = 10004, GPUFamily2_v1 = 10005.
        // v5/v6 were removed from the macOS 26 SDK headers; their wire
        // values (10006/10007) are carried over from older SDKs and should
        // be re-verified against a macOS 14 SDK header dump.
        let featureSets: [(String, UInt)] = [
            ("macOS_GPUFamily1_v1", 10000),
            ("macOS_GPUFamily1_v2", 10001),
            ("macOS_GPUFamily1_v3", 10003),
            ("macOS_GPUFamily1_v4", 10004),
            ("macOS_GPUFamily2_v1", 10005),
            ("macOS_GPUFamily1_v5", 10006),
            ("macOS_GPUFamily1_v6", 10007),
        ]
        let supported = featureSets.filter {
            supports(device, "supportsFeatureSet:", $0.1)
        }.map(\.0)
        info["featureSets"] = supported
        info["maxFeatureSet"] = supported.last ?? "none"

        // Limits + boolean capabilities, for the MPX-vs-retail feature
        // comparison in docs/metal/gpu-exposure.md.
        // NB: a device-level `threadExecutionWidth` selector exists on the
        // backing class but returns 0 on this driver; the real wave width
        // comes from pipelineCaps below.
        info["limits"] = [
            "maxThreadgroupMemoryLength": uintProperty(device, "maxThreadgroupMemoryLength") ?? 0,
            "maxBufferLength": uintProperty(device, "maxBufferLength") ?? 0,
        ]
        var caps: [String: Bool] = [:]
        for (key, sel) in [
            ("hasUnifiedMemory", "hasUnifiedMemory"),
            ("isLowPower", "isLowPower"),
            ("areRasterOrderGroupsSupported", "areRasterOrderGroupsSupported"),
            ("supports32BitFloatFiltering", "supports32BitFloatFiltering"),
            ("supportsPullModelInterpolation", "supportsPullModelInterpolation"),
            ("supportsVertexAmplification", "supportsVertexAmplification"),
        ] {
            if let v = boolProperty(device, sel) { caps[key] = v }
        }
        info["capabilities"] = caps

        // The device-level threadExecutionWidth is not exposed on this SDK;
        // query a compiled pipeline instead (it reports the device's wave
        // width). One trivial kernel per device, compiled once.
        let probeSource = "kernel void _probe(device float *p [[buffer(0)]], uint t [[thread_position_in_threadgroup]]) { p[t] = 1; }"
        if let lib = try? device.makeLibrary(source: probeSource, options: nil),
           let fn = lib.makeFunction(name: "_probe"),
           let pso = try? device.makeComputePipelineState(function: fn) {
            info["pipelineCaps"] = [
                "threadExecutionWidth": pso.threadExecutionWidth,
                "maxTotalThreadsPerThreadgroup": pso.maxTotalThreadsPerThreadgroup,
            ]
        }

        return info
    }

    /// Call `-(BOOL)selectorName:(NSUInteger)arg` on the device's backing
    /// ObjC class. Avoids MTLGPUFamily/MTLFeatureSet Swift-overlay churn
    /// across SDKs (both parameters are NSUInteger in the ObjC headers).
    private static func supports(_ device: MTLDevice, _ selectorName: String, _ arg: UInt) -> Bool {
        let sel = Selector(selectorName)
        guard let cls = object_getClass(device),
              let method = class_getInstanceMethod(cls, sel)
        else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Bool
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(device, sel, arg)
    }

    /// Read a no-argument `-(NSUInteger)selector` property (0 when absent).
    private static func uintProperty(_ device: MTLDevice, _ selectorName: String) -> Int? {
        let sel = Selector(selectorName)
        guard let cls = object_getClass(device),
              let method = class_getInstanceMethod(cls, sel)
        else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return Int(fn(device, sel))
    }

    /// Read a no-argument `-(BOOL)selector` property; nil when the selector
    /// is unavailable on this SDK/driver (so absence != false).
    private static func boolProperty(_ device: MTLDevice, _ selectorName: String) -> Bool? {
        let sel = Selector(selectorName)
        guard let cls = object_getClass(device),
              let method = class_getInstanceMethod(cls, sel)
        else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return fn(device, sel)
    }
}
