// probe.swift — Read-only probe: after a display is disconnected, which APIs can still "see" it?
//
// Build:  swiftc -O probe.swift -o probe
// Usage:  ./probe [extra IDs ...]      Queries IDs 1-8 plus every ID found in the lists
//
// This program only reads; it never calls anything that changes display state.
// Private function signatures are inferred from community sources; if one is wrong,
// the worst case is that this probe itself crashes. Displays are not affected.

import AppKit
import CoreGraphics
import IOKit

typealias DisplayID = CGDirectDisplayID
typealias PrivateListFn = @convention(c) (UInt32, UnsafeMutablePointer<DisplayID>?, UnsafeMutablePointer<UInt32>?) -> Int32

var seen = Set<DisplayID>(1...8)
CommandLine.arguments.dropFirst().compactMap { DisplayID($0) }.forEach { seen.insert($0) }

// MARK: - 1. Display lists

func report(_ name: String, _ get: (UnsafeMutablePointer<DisplayID>, UnsafeMutablePointer<UInt32>) -> Int32) {
    var buf = [DisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    let err = get(&buf, &count)
    guard err == 0 else { print("  \(name): error \(err)"); return }
    let ids = Array(buf.prefix(Int(min(count, 32))))
    seen.formUnion(ids)
    print("  \(name): \(ids)")
}

print("== 1. Display lists ==")
report("CGGetOnlineDisplayList (public)") { CGGetOnlineDisplayList(32, $0, $1).rawValue }
report("CGGetActiveDisplayList (public)") { CGGetActiveDisplayList(32, $0, $1).rawValue }
for name in ["CGSGetDisplayList", "SLSGetDisplayList", "CGSGetOnlineDisplayList", "SLSGetOnlineDisplayList"] {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {  // RTLD_DEFAULT
        print("  \(name) (private): symbol not found")
        continue
    }
    let fn = unsafeBitCast(sym, to: PrivateListFn.self)
    report("\(name) (private)") { fn(32, $0, $1) }
}

// MARK: - 2. Per-ID queries

func yn(_ v: boolean_t) -> String { v != 0 ? "yes" : "no" }

func uuidInfo(_ id: DisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "none" }
    let text = CFUUIDCreateString(nil, uuid) as String
    return "\(text) (UUID maps back to ID \(CGDisplayGetDisplayIDFromUUID(uuid)))"
}

print("\n== 2. Per-ID queries ==")
for id in seen.sorted() {
    print("  ID \(id): online=\(yn(CGDisplayIsOnline(id))) active=\(yn(CGDisplayIsActive(id))) builtin=\(yn(CGDisplayIsBuiltin(id)))"
          + " vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) serial=\(CGDisplaySerialNumber(id))"
          + " UUID=\(uuidInfo(id))")
}

// MARK: - 3. Hardware level (IOKit registry)

func prop(_ svc: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

print("\n== 3. Display devices in IOKit ==")
var printed = Set<UInt64>()  // The same entry can match several class names; de-duplicate by registry ID
for cls in ["IOMobileFramebuffer", "IOMobileFramebufferShim", "AppleCLCD2", "DCPAVServiceProxy", "IODisplayConnect"] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { continue }
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(svc, &entryID)
        let attrs = (prop(svc, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        let location = prop(svc, "Location")
        if (attrs != nil || location != nil), printed.insert(entryID).inserted {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(svc, &name)
            print("  [\(cls)] \(String(cString: name))  location=\(location ?? "-")"
                  + "  product=\(attrs?["ProductName"] ?? "-")  vendor=\(attrs?["LegacyManufacturerID"] ?? attrs?["ManufacturerID"] ?? "-")"
                  + "  model=\(attrs?["ProductID"] ?? "-")  serial=\(attrs?["SerialNumber"] ?? "-")")
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(iter)
    }
    IOObjectRelease(iter)
}
