// lid_watch.swift — Read-only test: print lid, sleep/wake and display-change events as they arrive.
//
// Build:  swiftc -O lid_watch.swift -o lid_watch
// Usage:  ./lid_watch | tee lid.log      (Ctrl+C to quit)
//
// Event sources (all public):
//   1. IOPMrootDomain general interest: kIOPMMessageClamshellStateChange (IOKit/pwr_mgt/IOPM.h)
//   2. IORegisterForSystemPower: system sleep / wake
//   3. CGDisplayRegisterReconfigurationCallback: display added / removed / enabled / disabled
// This program never changes display state.

import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

// These constants are C macros that Swift cannot import; values computed from the IOKit headers:
// iokit_family_msg(sub_iokit_powermanagement, 0x100) and iokit_common_msg(0x270 / 0x280 / 0x300 / 0x320).
let msgClamshellStateChange: UInt32 = 0xE003_4100
let msgCanSystemSleep: UInt32 = 0xE000_0270
let msgSystemWillSleep: UInt32 = 0xE000_0280
let msgSystemHasPoweredOn: UInt32 = 0xE000_0300
let msgSystemWillPowerOn: UInt32 = 0xE000_0320

let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

func log(_ msg: String) {
    print("\(timeFormat.string(from: Date()))  \(msg)")
    fflush(stdout)  // Keep output live when piped to tee
}

let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

// Current AppleClamshellState property, for cross-checking each event.
func lidState() -> String {
    let v = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
    return v.map { $0 ? "closed" : "open" } ?? "unknown"
}

func addToMainRunLoop(_ port: IONotificationPortRef) {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
}

// MARK: - 1. Clamshell messages from IOPMrootDomain

guard rootDomain != 0, let pmPort = IONotificationPortCreate(kIOMainPortDefault) else {
    print("IOPMrootDomain not found; cannot listen")
    exit(1)
}
addToMainRunLoop(pmPort)
var interestNotifier: io_object_t = 0
IOServiceAddInterestNotification(pmPort, rootDomain, "IOGeneralInterest", { _, _, type, arg in
    if type == msgClamshellStateChange {
        // Bit 0: 1 = closed; bit 1: 1 = closing the lid will put the system to sleep.
        let bits = Int(bitPattern: arg)
        log("Lid event: \(bits & 1 != 0 ? "closed" : "opened"), \(bits & 2 != 0 ? "closing sleeps" : "closing does not sleep")"
            + " (AppleClamshellState=\(lidState()))")
    } else {
        log("(other power message 0x\(String(type, radix: 16)))")
    }
}, nil, &interestNotifier)

// MARK: - 2. System sleep / wake

var rootPort: io_connect_t = 0
var powerPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, type, arg in
    switch type {
    case msgCanSystemSleep, msgSystemWillSleep:
        log(type == msgSystemWillSleep ? "System will sleep" : "System asks whether it can sleep")
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))  // Must acknowledge, or sleep is delayed
    case msgSystemWillPowerOn:
        log("System is waking up")
    case msgSystemHasPoweredOn:
        log("System has woken up (AppleClamshellState=\(lidState()))")
    default:
        break
    }
}, &powerNotifier)
if rootPort != 0, let powerPort { addToMainRunLoop(powerPort) } else { log("Warning: could not register for sleep / wake notifications") }

// MARK: - 3. Display reconfiguration

CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let names: [(CGDisplayChangeSummaryFlags, String)] = [
        (.addFlag, "added"), (.removeFlag, "removed"), (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
        (.mirrorFlag, "mirrored"), (.unMirrorFlag, "unmirrored"), (.setMainFlag, "set as main"),
    ]
    let parts = names.filter { flags.contains($0.0) }.map { $0.1 }
    log("Display change: ID \(id) " + (parts.isEmpty ? "other (flags=0x\(String(flags.rawValue, radix: 16)))" : parts.joined(separator: ", ")))
}, nil)

// MARK: - Run

log("Listening (lid: \(lidState())). Press Ctrl+C to quit")
CFRunLoopRun()
