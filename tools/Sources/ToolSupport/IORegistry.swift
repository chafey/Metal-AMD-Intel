import Foundation
import IOKit

// Thin Swift wrappers over the IOKit registry APIs gpu-probe needs:
// enumerate PCI devices, index registry ids, and read/scan properties.

/// One `IOPCIDevice` and everything hanging below it in the IOService plane.
/// A class so `deinit` can release the held IOKit references.
final public class PCISubtree {
    public let device: io_registry_entry_t  // owned (retained)
    public let serviceName: String
    /// All entries in the subtree (including the device itself), keyed by
    /// their IOKit registry-entry id. Used to resolve `MTLDevice.registryID`.
    public var entriesByID: [UInt64: io_registry_entry_t]  // owned
    /// Same entries as a flat list, for property scans.
    public var allEntries: [io_registry_entry_t]  // owned

    public init(device: io_registry_entry_t) {
        self.device = device
        IOObjectRetain(device)

        var nameBuf = [CChar](repeating: 0, count: 256)
        IORegistryEntryGetName(device, &nameBuf)
        serviceName = String(cString: nameBuf)

        entriesByID = [:]
        allEntries = []
        for entry in Self.serviceSubtree(of: device) {
            // serviceSubtree hands over +1 ownership of every entry.
            allEntries.append(entry)
            if let id = IORegistryHelper.entryID(of: entry) {
                entriesByID[id] = entry
            }
        }
    }

    deinit {
        IOObjectRelease(device)
        for entry in allEntries { IOObjectRelease(entry) }
    }

    /// Recursive IOService-plane walk rooted at `entry` (includes `entry`).
    /// Returns +1-owned references for every entry.
    public static func serviceSubtree(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var result: [io_registry_entry_t] = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            entry, "IOService",
            IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != 0 {
            result.append(child)  // iterator hands over +1 ownership
            child = IOIteratorNext(iterator)
        }
        IOObjectRetain(entry)
        result.insert(entry, at: 0)
        return result
    }
}

public enum IORegistryHelper {
    /// The C++ class name of a registry object.
    public static func className(of entry: io_registry_entry_t) -> String? {
        var classBuf = [CChar](repeating: 0, count: 256)
        guard IOObjectGetClass(entry, &classBuf) == KERN_SUCCESS else { return nil }
        return String(cString: classBuf)
    }

    /// Read a property as a plain Swift value (NSNumber/String/Data/...).
    public static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard
            let cf = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return cf.takeRetainedValue()
    }

    /// The IOKit registry-entry id of an entry (the value `MTLDevice`
    /// `registryID` is documented to correspond to).
    public static func entryID(of entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else {
            return nil
        }
        return id
    }

    /// Read a PCI-style numeric property. IOKit stores these as raw
    /// little-endian `Data` blobs (e.g. vendor-id `<00021000>` == 0x1002),
    /// though some drivers publish `OSNumber`; handle both.
    public static func numericProperty(_ entry: io_registry_entry_t, _ key: String) -> UInt64? {
        guard let value = property(entry, key) else { return nil }
        if let number = value as? NSNumber { return number.uint64Value }
        if let data = value as? Data, data.count <= 8 {
            var result: UInt64 = 0
            for (i, byte) in data.enumerated() { result |= UInt64(byte) << (8 * i) }
            return result
        }
        return nil
    }

    /// All IOPCIDevice services in the system. Each returned reference is
    /// owned by the caller (release with `IOObjectRelease`).
    public static func allPCIDevices() -> [io_registry_entry_t] {
        var result: [io_registry_entry_t] = []
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOPCIDevice") else { return result }
        // IOServiceGetMatchingServices consumes `matching`.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            result.append(service)  // iterator hands over +1 ownership
            service = IOIteratorNext(iterator)
        }
        return result
    }

    /// Nearest ancestor (inclusive) whose C++ class is `className`. The
    /// returned reference is +1-owned by the caller (release it).
    public static func ancestor(of entry: io_registry_entry_t, conformingTo className: String) -> io_registry_entry_t? {
        var current = entry
        IOObjectRetain(current)
        while current != 0 {
            if IOObjectConformsTo(current, className) != 0 { return current }
            var parent: io_registry_entry_t = 0
            let kr = "IOService".withCString { cPlane in
                IORegistryEntryGetParentEntry(current, cPlane, &parent)
            }
            IOObjectRelease(current)
            current = kr == KERN_SUCCESS ? parent : 0
        }
        return nil
    }

    /// All (node, key, value) triples in `entries` for `keys` — one per
    /// (node, key), duplicates across shared paths deduplicated.
    public static func scanAll(
        entries: [io_registry_entry_t], forKeys keys: Set<String>
    ) -> [(node: String, key: String, value: Any)] {
        var seen = Set<String>()
        var results: [(node: String, key: String, value: Any)] = []
        for entry in entries {
            var nameBuf = [CChar](repeating: 0, count: 256)
            IORegistryEntryGetName(entry, &nameBuf)
            let nodeName = String(cString: nameBuf)
            for key in keys {
                guard let value = property(entry, key) else { continue }
                let id = "\(nodeName).\(key)=\(value)"
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                results.append((nodeName, key, value))
            }
        }
        return results.sorted { ($0.key, $0.node) < ($1.key, $1.node) }
    }

    /// All properties on `entries` whose name contains `substring`
    /// (case-insensitive). Entries reachable via multiple paths are
    /// deduplicated by (node, key).
    public static func properties(
        matching substring: String, in entries: [io_registry_entry_t]
    ) -> [(node: String, key: String, value: Any)] {
        var results: [(node: String, key: String, value: Any)] = []
        var seen = Set<String>()
        for entry in entries {
            var nameBuf = [CChar](repeating: 0, count: 256)
            IORegistryEntryGetName(entry, &nameBuf)
            let nodeName = String(cString: nameBuf)
            var dict: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                entry, &dict, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS, let props = dict?.takeRetainedValue() as? [String: Any]
            else { continue }
            for (key, value) in props where key.lowercased().contains(substring) {
                guard !seen.contains("\(nodeName).\(key)") else { continue }
                seen.insert("\(nodeName).\(key)")
                results.append((nodeName, key, value))
            }
        }
        return results.sorted { $0.key < $1.key }
    }
}
