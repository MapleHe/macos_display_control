// display_control.swift — Disconnect / reconnect displays from the command line
// (similar to BetterDisplay's Disconnect / Connect).
//
// Build:  swiftc -O display_control.swift -o display_control
// Usage:
//   display_control list                 Live scan: display states and available actions
//   display_control off [ID|builtin]     Disconnect; without an argument, pick from a menu
//   display_control on  [ID|all]         Reconnect;  without an argument, pick from a menu
//
// Notes (verified on Apple Silicon MacBook Air):
// - No state file. Every command scans live and only offers displays that can be acted on;
//   with a single usable display left, nothing can be disconnected.
// - A disabled display drops out of the public online list but stays in the private
//   CGSGetDisplayList, so "in CGSGetDisplayList but not online" means disconnected.
// - The flag is set via the private CGSConfigureDisplayEnabled with .forSession scope:
//   it survives lid close/open and unplug/replug, and is cleared only by `on`, logout or reboot.
// - A disabled external display stays in CGSGetDisplayList after being unplugged, so IOKit is
//   used to check whether it is still physically attached. (The built-in panel's IOKit entry
//   disappears while disabled, so the built-in is always treated as attached.)
// - Only IDs taken from the lists are ever queried: for unknown IDs, CGDisplayIsActive and
//   friends return meaningless "true" values.

import AppKit
import IOKit

typealias DisplayID = CGDirectDisplayID

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Private API

// Reverse-engineered declarations (used by displayplacer et al.), verified on this machine:
//   CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
//   CGError CGSGetDisplayList(uint32_t max, CGDirectDisplayID *ids, uint32_t *count)
// The bool is passed as Int32 0/1, which reads the same whether the callee expects bool or int.
typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, DisplayID, Int32) -> Int32
typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<DisplayID>?, UnsafeMutablePointer<UInt32>?) -> Int32

func privateSymbol<T>(_ names: [String], as type: T.Type) -> T? {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT: already-loaded images only
    for name in names {
        if let sym = dlsym(rtldDefault, name) { return unsafeBitCast(sym, to: type) }
    }
    return nil
}

let configureEnabled = privateSymbol(["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"], as: ConfigureEnabledFn.self)
let getAllDisplays = privateSymbol(["CGSGetDisplayList", "SLSGetDisplayList"], as: ListFn.self)
let missingAPI = Failure("CGSConfigureDisplayEnabled not found on this system; cannot change displays")

// The only function that changes display state.
func configure(_ id: DisplayID, enabled: Bool) throws {
    guard let fn = configureEnabled else { throw missingAPI }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { throw Failure("CGBeginDisplayConfiguration failed") }
    let r = fn(cfg, id, enabled ? 1 : 0)
    guard r == CGError.success.rawValue else {
        CGCancelDisplayConfiguration(cfg)
        throw Failure("ConfigureDisplayEnabled(\(id), \(enabled)) returned \(r)")
    }
    let done = CGCompleteDisplayConfiguration(cfg, .forSession)
    guard done == .success else { throw Failure("CGCompleteDisplayConfiguration failed: \(done.rawValue)") }
}

// MARK: - Live scan

func displayList(_ get: (UInt32, UnsafeMutablePointer<DisplayID>, UnsafeMutablePointer<UInt32>) -> Int32) -> [DisplayID] {
    var ids = [DisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    return get(32, &ids, &count) == 0 ? Array(ids.prefix(Int(min(count, 32)))) : []
}

func activeDisplays() -> [DisplayID] { displayList { CGGetActiveDisplayList($0, $1, $2).rawValue } }
func onlineDisplays() -> [DisplayID] { displayList { CGGetOnlineDisplayList($0, $1, $2).rawValue } }
// Includes disconnected displays; falls back to the online list if the private symbol is missing.
func allDisplays() -> [DisplayID] {
    guard let fn = getAllDisplays else { return onlineDisplays() }
    return displayList { fn($0, $1, $2) }
}

// Enabled = active, or online in a mirror set (hardware-mirrored secondaries are not "active").
func isEnabled(_ id: DisplayID) -> Bool {
    activeDisplays().contains(id) || (onlineDisplays().contains(id) && CGDisplayIsInMirrorSet(id) != 0)
}

struct Panel {  // A display physically attached according to IOKit
    let vendor, model: UInt32
    let name: String
}

// Displays attached at the IOKit level (Apple Silicon). nil means "cannot tell".
func attachedPanels() -> [Panel]? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iter) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iter) }
    var panels: [Panel] = []
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        let attrs = IORegistryEntryCreateCFProperty(svc, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        if let p = attrs?["ProductAttributes"] as? [String: Any],
           let vendor = p["LegacyManufacturerID"] as? NSNumber, let model = p["ProductID"] as? NSNumber {
            panels.append(Panel(vendor: vendor.uint32Value, model: model.uint32Value, name: p["ProductName"] as? String ?? "Unnamed"))
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(iter)
    }
    return panels.isEmpty ? nil : panels
}

struct Scan {
    let all, online, active: [DisplayID]
    let names: [DisplayID: String]  // Only active displays have an NSScreen name
    let panels: [Panel]?
}

func scan() -> Scan {
    var names: [DisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[n.uint32Value] = screen.localizedName
        }
    }
    return Scan(all: allDisplays(), online: onlineDisplays(), active: activeDisplays(),
                names: names, panels: attachedPanels())
}

// Match an external display to IOKit by vendor + model (two identical monitors are indistinguishable).
func panel(for id: DisplayID, _ s: Scan) -> Panel? {
    s.panels?.first { $0.vendor == CGDisplayVendorNumber(id) && $0.model == CGDisplayModelNumber(id) }
}

// Built-in is always attached; if IOKit cannot tell, assume attached and let `on` report the result.
func isAttached(_ id: DisplayID, _ s: Scan) -> Bool {
    CGDisplayIsBuiltin(id) != 0 || s.panels == nil || panel(for: id, s) != nil
}

// Can disconnect: active, not mirrored, and at least one other awake active display remains.
func offCandidates(_ s: Scan) -> [DisplayID] {
    s.active.filter { id in
        CGDisplayIsInMirrorSet(id) == 0 && s.active.contains { $0 != id && CGDisplayIsAsleep($0) == 0 }
    }
}

// Can reconnect: known to the system, not online, and still physically attached.
func onCandidates(_ s: Scan) -> [DisplayID] {
    s.all.filter { !s.online.contains($0) && isAttached($0, s) }.sorted()
}

func label(_ id: DisplayID, _ s: Scan) -> String {
    if CGDisplayIsBuiltin(id) != 0 { return "[\(id)] \(s.names[id] ?? "Built-in Display") (built-in)" }
    let name = s.names[id] ?? panel(for: id, s)?.name
        ?? "External Display (vendor \(CGDisplayVendorNumber(id)), model \(CGDisplayModelNumber(id)))"
    return "[\(id)] \(name)"
}

func status(_ id: DisplayID, _ s: Scan) -> String {
    if !s.online.contains(id) { return isAttached(id, s) ? "disconnected" : "disconnected (cable unplugged; plug it back in to reconnect)" }
    if isEnabled(id) { return CGDisplayIsInMirrorSet(id) != 0 ? "connected (mirrored)" : "connected" }
    return CGDisplayIsAsleep(id) != 0 ? "asleep" : "online but not enabled"
}

// Wait up to 3 s for the condition, then re-check after 0.5 s so a transient state during
// re-enumeration is not taken as the result. Running the run loop lets display-change
// notifications be processed; if it has no sources it returns at once, so sleep instead.
func waitStable(_ cond: () -> Bool) -> Bool {
    func pause(_ t: Double) {
        if CFRunLoopRunInMode(.defaultMode, t, false) == .finished { Thread.sleep(forTimeInterval: t) }
    }
    let deadline = Date().addingTimeInterval(3)
    while !cond() {
        if Date() > deadline { return false }
        pause(0.1)
    }
    pause(0.5)
    return cond()
}

// MARK: - Target selection (only from candidates found by the current scan)

func pick(_ arg: String?, from candidates: [DisplayID], _ s: Scan, verb: String, none: String) throws -> DisplayID {
    guard !candidates.isEmpty else { throw Failure(none) }

    if let arg {
        let id = arg == "builtin" ? candidates.first(where: { CGDisplayIsBuiltin($0) != 0 }) : DisplayID(arg)
        guard let id, candidates.contains(id) else {
            throw Failure("\(arg) cannot be \(verb) right now. Options: " + candidates.map { label($0, s) }.joined(separator: ", "))
        }
        return id
    }

    print("Displays that can be \(verb):")
    for (i, id) in candidates.enumerated() { print("  \(i + 1). \(label(id, s))  \(status(id, s))") }
    print("Enter a number (Enter to cancel): ", terminator: "")
    fflush(stdout)
    guard let line = readLine(), let n = Int(line.trimmingCharacters(in: .whitespaces)),
          candidates.indices.contains(n - 1) else { throw Failure("Cancelled") }
    return candidates[n - 1]
}

// MARK: - Commands

func cmdList() {
    let s = scan()
    print("Displays (live scan):")
    for id in s.all.sorted() {
        var line = "  \(label(id, s))  \(status(id, s))"
        if s.active.contains(id) {
            line += "  \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
            if CGDisplayIsMain(id) != 0 { line += "  main" }
        }
        print(line)
    }
    let off = offCandidates(s).map { String($0) }, on = onCandidates(s).map { String($0) }
    print("Can disconnect: " + (off.isEmpty ? "none (at least one usable display must remain)" : off.joined(separator: ", ")))
    print("Can reconnect:  " + (on.isEmpty ? "none" : on.joined(separator: ", ")))
    if getAllDisplays == nil { print("Warning: CGSGetDisplayList not found; disconnected displays cannot be listed") }
}

func cmdOff(_ arg: String?) throws {
    let first = scan()
    let target = try pick(arg, from: offCandidates(first), first, verb: "disconnected",
                          none: "Only one usable display left (mirrored or asleep ones do not count); nothing can be disconnected")

    // State may have changed while the menu was open: re-check right before committing.
    let s = scan()
    guard offCandidates(s).contains(target) else { throw Failure("Display state changed; please run the command again") }
    if CGDisplayIsMain(target) != 0 { print("Note: this is the main display; the menu bar will move to another display") }

    do { try configure(target, enabled: false) } catch { print("Warning: \(error)") }

    // Judge by actual state: target is gone and another awake active display remains.
    let gone = waitStable { !isEnabled(target) }
    if gone && activeDisplays().contains(where: { $0 != target && CGDisplayIsAsleep($0) == 0 }) {
        print("Disconnected \(label(target, s))")
        return
    }

    // Failed: try to restore the original state.
    if !isEnabled(target) {
        try? configure(target, enabled: true)
        _ = waitStable { isEnabled(target) }
    }
    throw Failure((gone ? "No other usable display after disconnecting" : "Disconnect did not take effect")
                  + (isEnabled(target) ? "; original state restored" : "; automatic restore failed: log out or reboot"))
}

func cmdOn(_ arg: String?) throws {
    let s = scan()
    let candidates = onCandidates(s)
    if arg == "all" && candidates.isEmpty { print("No display to reconnect"); return }
    let targets = try arg == "all" ? candidates
        : [pick(arg, from: candidates, s, verb: "reconnected", none: "No display to reconnect")]

    var failed: [String] = []
    for id in targets {
        do { try configure(id, enabled: true) } catch { print("Warning: \(error)") }
        if waitStable({ isEnabled(id) }) { print("Reconnected \(label(id, s))") } else { failed.append(label(id, s)) }
    }
    if !failed.isEmpty { throw Failure("Could not reconnect \(failed.joined(separator: ", ")). Try logging out or rebooting") }
}

// MARK: - Entry point

let usage = """
Usage:
  display_control list                 List displays and available actions
  display_control off [ID|builtin]     Disconnect a display (menu if no argument)
  display_control on  [ID|all]         Reconnect a display (menu if no argument)
"""

let args = Array(CommandLine.arguments.dropFirst())
let argTarget = args.count == 2 ? args[1] : nil
do {
    switch (args.first ?? "list", args.count) {
    case ("list", 0...1): cmdList()
    case ("off", 1...2), ("on", 1...2):
        guard configureEnabled != nil else { throw missingAPI }  // Fail fast instead of a misleading verify timeout
        try args[0] == "off" ? cmdOff(argTarget) : cmdOn(argTarget)
    default:
        print(usage)
        exit(2)
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
